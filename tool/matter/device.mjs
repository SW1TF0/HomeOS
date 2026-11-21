// Simulated Matter device for interop tests. Usage: node device.mjs <port> <light|bridge|robot> <storageDir>
import { Endpoint, Environment, ServerNode, VendorId, StorageService, Logger, LogLevel } from "@matter/main";
import { ExtendedColorLightDevice } from "@matter/main/devices/extended-color-light";
import { OnOffPlugInUnitDevice } from "@matter/main/devices/on-off-plug-in-unit";
import { TemperatureSensorDevice } from "@matter/main/devices/temperature-sensor";
import { AggregatorEndpoint } from "@matter/main/endpoints/aggregator";
import { BridgedDeviceBasicInformationServer } from "@matter/main/behaviors/bridged-device-basic-information";
import { RoboticVacuumCleanerDevice, RoboticVacuumCleanerRequirements } from "@matter/main/devices/robotic-vacuum-cleaner";
import { AirPurifierDevice } from "@matter/main/devices/air-purifier";
import { WaterValveDevice } from "@matter/main/devices/water-valve";
import { LaundryWasherDevice } from "@matter/main/devices/laundry-washer";
import { SmokeCoAlarmDevice } from "@matter/main/devices/smoke-co-alarm";
import { RvcRunModeServer } from "@matter/main/behaviors/rvc-run-mode";
import { RvcCleanModeServer } from "@matter/main/behaviors/rvc-clean-mode";
import { PowerSourceServer } from "@matter/main/behaviors/power-source";
import { FanControlServer } from "@matter/main/behaviors/fan-control";
import { ValveConfigurationAndControlServer } from "@matter/main/behaviors/valve-configuration-and-control";
import { OperationalStateServer } from "@matter/main/behaviors/operational-state";
import { LaundryWasherModeServer } from "@matter/main/behaviors/laundry-washer-mode";
import { SmokeCoAlarmServer } from "@matter/main/behaviors/smoke-co-alarm";
import { Pm25ConcentrationMeasurementServer } from "@matter/main/behaviors/pm25-concentration-measurement";
import { FanControl, PowerSource, SmokeCoAlarm, ConcentrationMeasurement } from "@matter/main/clusters";

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
    productDescription: { name: `Sim ${kind}`, deviceType: { bridge: 0x000e, robot: 0x0074 }[kind] ?? 0x010d },
    basicInformation: {
        vendorName: "matter.js", vendorId: VendorId(0xfff1), nodeLabel: `Sim ${kind}`,
        productName: { bridge: "Sim bridge", robot: "Sim robot" }[kind] ?? "Sim color light", productLabel: "Sim",
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
} else if (kind === "robot") {
    await addAppliances(node);
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

// A robot vacuum, an air purifier, a water valve, a washing machine and a smoke alarm, each printing what it is told.
async function addAppliances(node) {
    const ok = { commandResponseState: { errorStateId: 0 } };
    const said = command => console.log(`COMMAND ${command}`);
    const IDLE = 0, CLEANING = 1, STOPPED = 0, RUNNING = 1, PAUSED = 2, SEEKING_CHARGER = 0x40, DOCKED = 0x42;

    class RobotState extends RoboticVacuumCleanerRequirements.RvcOperationalStateServer {
        pause() { said("pause"); this.state.operationalState = PAUSED; return ok; }
        resume() { said("resume"); this.state.operationalState = RUNNING; return ok; }
        goHome() {
            said("goHome");
            this.state.operationalState = SEEKING_CHARGER;
            this.agent.get(RobotRunMode).state.currentMode = IDLE;
            return ok;
        }
    }
    class RobotRunMode extends RvcRunModeServer {
        changeToMode(request) {
            said(`run ${request.newMode}`);
            const result = super.changeToMode(request);
            if (result.status === 0) {
                this.agent.get(RobotState).state.operationalState = request.newMode === CLEANING ? RUNNING : SEEKING_CHARGER;
            }
            return result;
        }
    }
    const robot = new Endpoint(
        RoboticVacuumCleanerDevice.with(RobotState, RobotRunMode, RvcCleanModeServer, PowerSourceServer.with(PowerSource.Feature.Battery)),
        {
            id: "robot",
            rvcRunMode: {
                supportedModes: [
                    { label: "Idle", mode: IDLE, modeTags: [{ value: 0x4000 }] },
                    { label: "Cleaning", mode: CLEANING, modeTags: [{ value: 0x4001 }] },
                ],
                currentMode: IDLE,
            },
            rvcCleanMode: {
                supportedModes: [
                    { label: "Vacuum", mode: 0, modeTags: [{ value: 0x4001 }] },
                    { label: "Mop", mode: 1, modeTags: [{ value: 0x4002 }] },
                    { label: "Deep clean", mode: 2, modeTags: [{ value: 0x4000 }, { value: 0x4001 }] },
                ],
                currentMode: 0,
            },
            rvcOperationalState: {
                operationalStateList: [STOPPED, RUNNING, PAUSED, 3, SEEKING_CHARGER, 0x41, DOCKED].map(id => ({ operationalStateId: id })),
                operationalState: DOCKED,
                operationalError: { errorStateId: 0 },
                phaseList: null,
                currentPhase: null,
            },
            powerSource: {
                status: PowerSource.PowerSourceStatus.Active, order: 0, description: "Battery", endpointList: [],
                batPercentRemaining: 160, batChargeLevel: PowerSource.BatChargeLevel.Ok,
                batReplacementNeeded: false, batReplaceability: PowerSource.BatReplaceability.NotReplaceable,
            },
        },
    );
    await node.add(robot);
    robot.events.rvcOperationalState.operationalState$Changed.on(v => console.log(`STATE robot=${v}`));
    robot.events.rvcRunMode.currentMode$Changed.on(v => console.log(`STATE run=${v}`));
    robot.events.rvcCleanMode.currentMode$Changed.on(v => console.log(`STATE clean=${v}`));
    robot.events.identify.identifyTime$Changed.on(v => console.log(`STATE identify=${v}`));

    class Fan extends FanControlServer.with(FanControl.Feature.Auto) {
        initialize() {
            super.initialize();
            // Offline: the reactions change read-only attributes, which the client that wrote may not.
            this.reactTo(this.events.percentSetting$Changed, this.#percent, { offline: true });
            this.reactTo(this.events.fanMode$Changed, this.#mode, { offline: true });
        }
        #percent(v) {
            if (v === null) return;
            this.state.percentCurrent = v;
            const mode = v === 0 ? 0 : v <= 33 ? 1 : v <= 66 ? 2 : 3;
            if (this.state.fanMode !== mode) this.state.fanMode = mode;
        }
        #mode(m) {
            if (m === 0) this.state.percentSetting = 0;
            if (m === 5) this.state.percentCurrent = 40;
        }
    }
    const purifier = new Endpoint(
        AirPurifierDevice.with(Fan, Pm25ConcentrationMeasurementServer.with(ConcentrationMeasurement.Feature.NumericMeasurement)),
        {
            id: "purifier",
            fanControl: { fanMode: 0, fanModeSequence: FanControl.FanModeSequence.OffLowMedHighAuto, percentSetting: 0, percentCurrent: 0 },
            pm25ConcentrationMeasurement: {
                measuredValue: 12, minMeasuredValue: 0, maxMeasuredValue: 1000,
                measurementUnit: ConcentrationMeasurement.MeasurementUnit.Ugm3, measurementMedium: ConcentrationMeasurement.MeasurementMedium.Air,
            },
        },
    );
    await node.add(purifier);
    purifier.events.fanControl.fanMode$Changed.on(v => console.log(`STATE fanMode=${v}`));
    purifier.events.fanControl.percentSetting$Changed.on(v => console.log(`STATE percent=${v}`));

    class Valve extends ValveConfigurationAndControlServer {
        open() { this.state.targetState = 1; this.state.currentState = 1; }
        close() { this.state.targetState = 0; this.state.currentState = 0; }
    }
    const valve = new Endpoint(WaterValveDevice.with(Valve), {
        id: "valve",
        valveConfigurationAndControl: { currentState: 0, targetState: 0, openDuration: null, defaultOpenDuration: null, remainingDuration: null },
    });
    await node.add(valve);
    valve.events.valveConfigurationAndControl.currentState$Changed.on(v => console.log(`STATE valve=${v}`));

    class Washer extends OperationalStateServer {
        start() { said("start"); this.state.operationalState = RUNNING; this.state.countdownTime = 2700; return ok; }
        stop() { said("stop"); this.state.operationalState = STOPPED; this.state.countdownTime = null; return ok; }
        pause() { said("pause"); this.state.operationalState = PAUSED; return ok; }
        resume() { said("resume"); this.state.operationalState = RUNNING; return ok; }
    }
    const washer = new Endpoint(LaundryWasherDevice.with(Washer, LaundryWasherModeServer), {
        id: "washer",
        operationalState: {
            operationalStateList: [STOPPED, RUNNING, PAUSED, 3].map(id => ({ operationalStateId: id })),
            operationalState: STOPPED, operationalError: { errorStateId: 0 }, phaseList: null, currentPhase: null, countdownTime: null,
        },
        laundryWasherMode: {
            supportedModes: [
                { label: "Normal", mode: 0, modeTags: [{ value: 0x4000 }] },
                { label: "Delicate", mode: 1, modeTags: [{ value: 0x4001 }] },
                { label: "Heavy", mode: 2, modeTags: [{ value: 0x4002 }] },
            ],
            currentMode: 0,
        },
    });
    await node.add(washer);
    washer.events.operationalState.operationalState$Changed.on(v => console.log(`STATE washer=${v}`));
    washer.events.laundryWasherMode.currentMode$Changed.on(v => console.log(`STATE program=${v}`));

    const smoke = new Endpoint(SmokeCoAlarmDevice.with(SmokeCoAlarmServer.with(SmokeCoAlarm.Feature.SmokeAlarm, SmokeCoAlarm.Feature.CoAlarm)), {
        id: "smoke",
        smokeCoAlarm: {
            expressedState: SmokeCoAlarm.ExpressedState.Normal, smokeState: SmokeCoAlarm.AlarmState.Normal, coState: SmokeCoAlarm.AlarmState.Warning,
            batteryAlert: SmokeCoAlarm.AlarmState.Normal, testInProgress: false, hardwareFaultAlert: false,
            endOfServiceAlert: SmokeCoAlarm.EndOfService.Normal,
        },
    });
    await node.add(smoke);
}

node.events.commissioning.commissioned.on(() => console.log("EVENT commissioned"));
await node.start();
console.log("READY");
