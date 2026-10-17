// Simulated Matter device for interop tests. Usage: node device.mjs <port> <kind> <storageDir>
import { Endpoint, Environment, ServerNode, VendorId, StorageService, Logger, LogLevel } from "@matter/main";
import { ExtendedColorLightDevice } from "@matter/main/devices/extended-color-light";
import { OnOffPlugInUnitDevice } from "@matter/main/devices/on-off-plug-in-unit";
import { TemperatureSensorDevice } from "@matter/main/devices/temperature-sensor";
import { AggregatorEndpoint } from "@matter/main/endpoints/aggregator";
import { BridgedDeviceBasicInformationServer } from "@matter/main/behaviors/bridged-device-basic-information";

// The test container has no IPv6, which matter.js insists on: hand it a silent IPv6 socket
// and let the real IPv4 socket on the same port carry the traffic.
const { NodeJsNetwork } = await import("@matter/main/nodejs").catch(() => import("@matter/nodejs"));
const realCreate = NodeJsNetwork.prototype.createUdpSocket;
NodeJsNetwork.prototype.createUdpSocket = function (options) {
    if (options.type !== "udp6") return realCreate.call(this, options);
    const port = options.listeningPort ?? 0;
    return Promise.resolve({
        maxPayloadSize: 1232,
        addMembership() {}, dropMembership() {},
        onData() { return { close: async () => {} }; },
        async send() {}, async close() {},
        get port() { return port; },
        supports(type, address) { return false; },
    });
};

const [port = "5540", kind = "light", storage = "store"] = process.argv.slice(2);
const env = Environment.default;
env.vars.set("storage.path", storage);
env.vars.set("mdns.networkInterface", "lo");
Logger.level = process.env.MLOG === "debug" ? LogLevel.DEBUG : LogLevel.INFO;

const node = await ServerNode.create({
    id: `sim-${kind}`,
    network: { port: Number(port) },
    commissioning: { passcode: 20202021, discriminator: 3840 },
    productDescription: { name: `Sim ${kind}`, deviceType: kind === "bridge" ? 0x000e : 0x010d },
    basicInformation: {
        vendorName: "matter.js", vendorId: VendorId(0xfff1), nodeLabel: `Sim ${kind}`,
        productName: kind === "bridge" ? "Sim bridge" : "Sim color light", productLabel: "Sim",
        productId: 0x8000, serialNumber: `sim-${kind}-1`, uniqueId: `sim-${kind}-1`,
    },
});

if (kind === "bridge") {
    const agg = new Endpoint(AggregatorEndpoint, { id: "aggregator" });
    await node.add(agg);
    for (const [id, name] of [["plug1", "Kettle plug"], ["plug2", "Fan plug"]]) {
        await agg.add(new Endpoint(OnOffPlugInUnitDevice.with(BridgedDeviceBasicInformationServer), {
            id, bridgedDeviceBasicInformation: { nodeLabel: name, productName: "Plug", reachable: true, uniqueId: id },
        }));
    }
    await agg.add(new Endpoint(TemperatureSensorDevice.with(BridgedDeviceBasicInformationServer), {
        id: "temp", bridgedDeviceBasicInformation: { nodeLabel: "Hall sensor", reachable: true, uniqueId: "temp" },
        temperatureMeasurement: { measuredValue: 2150, minMeasuredValue: -4000, maxMeasuredValue: 8000 },
    }));
} else {
    const light = new Endpoint(ExtendedColorLightDevice, {
        id: "light",
        colorControl: { colorTempPhysicalMinMireds: 153, colorTempPhysicalMaxMireds: 500, coupleColorTempToLevelMinMireds: 153, colorTemperatureMireds: 250, colorMode: 2, enhancedColorMode: 2, currentX: 24939, currentY: 24701, numberOfPrimaries: null, options: { executeIfOff: false }, remainingTime: 0 },
    });
    await node.add(light);
    light.events.onOff.onOff$Changed.on(v => console.log(`STATE onOff=${v}`));
    light.events.levelControl.currentLevel$Changed.on(v => console.log(`STATE level=${v}`));
    light.events.colorControl.colorTemperatureMireds$Changed.on(v => console.log(`STATE mireds=${v}`));
    light.events.colorControl.currentX$Changed.on(v => console.log(`STATE x=${v}`));
}

node.events.commissioning.commissioned.on(() => console.log("EVENT commissioned"));
await node.start();
console.log("READY");
