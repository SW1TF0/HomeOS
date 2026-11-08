package com.smartmenukj.app.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import com.smartmenukj.core.integrations.FoundService
import com.smartmenukj.core.integrations.NetworkScanner
import com.smartmenukj.core.net.UrlHttp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.Inet4Address
import java.util.concurrent.ConcurrentHashMap

/**
 * Scan network: the phone's own mDNS browser (NsdManager), the free Hue discovery service, and a knock on every
 * address of the home Wi-Fi.
 */
class Scan(private val context: Context) {
    private val scanner = NetworkScanner(UrlHttp())

    /** This phone's IPv4 address on Wi-Fi (or Ethernet), or null when it is on mobile data only. */
    fun localAddress(): String? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val addr = cm.getLinkProperties(n)?.linkAddresses?.map { it.address }?.firstOrNull { it is Inet4Address }
            if (addr != null) return addr.hostAddress
        }
        return null
    }

    /** Runs every search at once and reports each thing found once. */
    suspend fun run(onFound: (FoundService) -> Unit) = coroutineScope {
        val seen = ConcurrentHashMap.newKeySet<String>()
        val emit = { f: FoundService -> if (seen.add(f.key)) launch(Dispatchers.Main) { onFound(f) } }
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val lock = wifi?.createMulticastLock("smartmenukj-scan")?.apply { setReferenceCounted(false); acquire() }
        try {
            launch { scanner.hueCloud().forEach { emit(it) } }
            launch { mdns(emit) }
            val ip = localAddress()
            if (ip != null) withContext(Dispatchers.IO) { scanner.sweep(NetworkScanner.subnetOf(ip)) { emit(it) } }
            delay(500)
        } finally {
            lock?.release()
        }
    }

    private suspend fun mdns(emit: (FoundService) -> Unit) {
        val nsd = context.getSystemService(NsdManager::class.java) ?: return
        val types = listOf("_hue._tcp", "_shelly._tcp", "_wled._tcp", "_esphomelib._tcp", "_home-assistant._tcp", "_http._tcp")
        val listeners = mutableListOf<NsdManager.DiscoveryListener>()
        for (type in types) {
            val l = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {}
                override fun onDiscoveryStopped(serviceType: String) {}
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
                override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    val integration = scanner.typeForService(type, info.serviceName) ?: return
                    resolve(nsd, info) { host, port -> emit(FoundService(info.serviceName, host, port, integration)) }
                }
            }
            runCatching { nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, l) }.onSuccess { listeners += l }
        }
        delay(6000)
        for (l in listeners) runCatching { nsd.stopServiceDiscovery(l) }
    }

    @Suppress("DEPRECATION")
    private fun resolve(nsd: NsdManager, info: NsdServiceInfo, done: (String, Int) -> Unit) {
        val l = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceResolved(s: NsdServiceInfo) {
                val host = if (Build.VERSION.SDK_INT >= 34) s.hostAddresses.firstOrNull { it is Inet4Address }?.hostAddress else s.host?.hostAddress
                if (host != null) done(host, s.port)
            }
        }
        runCatching { nsd.resolveService(info, l) }
    }
}
