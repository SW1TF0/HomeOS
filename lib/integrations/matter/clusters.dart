// Cluster, attribute and command ids used by this app (Matter application
// cluster specification), and the device types it knows.

class Cluster {
  static const identify = 0x0003;
  static const onOff = 0x0006;
  static const levelControl = 0x0008;
  static const descriptor = 0x001d;
  static const basicInformation = 0x0028;
  static const powerSource = 0x002f;
  static const generalCommissioning = 0x0030;
  static const bridgedDeviceBasicInformation = 0x0039;
  static const operationalCredentials = 0x003e;
  static const booleanState = 0x0045;
  static const doorLock = 0x0101;
  static const windowCovering = 0x0102;
  static const thermostat = 0x0201;
  static const fanControl = 0x0202;
  static const colorControl = 0x0300;
  static const illuminanceMeasurement = 0x0400;
  static const temperatureMeasurement = 0x0402;
  static const pressureMeasurement = 0x0403;
  static const relativeHumidityMeasurement = 0x0405;
  static const occupancySensing = 0x0406;
}

/// Global attributes every cluster has.
class GlobalAttr {
  static const featureMap = 0xfffc;
  static const clusterRevision = 0xfffd;
}

class DescriptorAttr {
  static const deviceTypeList = 0x0000;
  static const serverList = 0x0001;
  static const clientList = 0x0002;
  static const partsList = 0x0003;
}

class BasicInfoAttr {
  static const vendorName = 0x0001;
  static const vendorId = 0x0002;
  static const productName = 0x0003;
  static const productId = 0x0004;
  static const nodeLabel = 0x0005;
  static const location = 0x0006;
  static const softwareVersionString = 0x000a;
  static const serialNumber = 0x000f;
  static const reachable = 0x0011;
  static const uniqueId = 0x0012;
}

class GeneralCommissioning {
  static const breadcrumb = 0x0000;
  static const basicCommissioningInfo = 0x0001;
  static const regulatoryConfig = 0x0002;
  static const locationCapability = 0x0003;

  static const armFailSafe = 0x00;
  static const setRegulatoryConfig = 0x02;
  static const commissioningComplete = 0x04;
}

class OperationalCredentials {
  static const nocs = 0x0000;
  static const fabrics = 0x0001;
  static const supportedFabrics = 0x0002;
  static const commissionedFabrics = 0x0003;
  static const currentFabricIndex = 0x0005;

  static const attestationRequest = 0x00;
  static const certificateChainRequest = 0x02;
  static const csrRequest = 0x04;
  static const addNoc = 0x06;
  static const updateFabricLabel = 0x09;
  static const removeFabric = 0x0a;
  static const addTrustedRootCertificate = 0x0b;
}

class OnOff {
  static const onOff = 0x0000;

  static const off = 0x00;
  static const on = 0x01;
  static const toggle = 0x02;
}

class LevelControl {
  static const currentLevel = 0x0000;
  static const minLevel = 0x0002;
  static const maxLevel = 0x0003;

  static const moveToLevel = 0x00;
  static const moveToLevelWithOnOff = 0x04;
}

class ColorControl {
  static const currentHue = 0x0000;
  static const currentSaturation = 0x0001;
  static const currentX = 0x0003;
  static const currentY = 0x0004;
  static const colorTemperatureMireds = 0x0007;
  static const colorMode = 0x0008;
  static const colorCapabilities = 0x400a;
  static const colorTempPhysicalMinMireds = 0x400b;
  static const colorTempPhysicalMaxMireds = 0x400c;

  static const moveToHue = 0x00;
  static const moveToSaturation = 0x03;
  static const moveToHueAndSaturation = 0x06;
  static const moveToColor = 0x07;
  static const moveToColorTemperature = 0x0a;

  /// Feature map bits.
  static const featureHueSaturation = 0x01;
  static const featureXy = 0x08;
  static const featureColorTemperature = 0x10;

  /// ColorMode values.
  static const modeHueSaturation = 0;
  static const modeXy = 1;
  static const modeColorTemperature = 2;
}

class WindowCovering {
  static const currentPositionLiftPercent100ths = 0x000e;

  static const upOrOpen = 0x00;
  static const downOrClose = 0x01;
  static const stopMotion = 0x02;
  static const goToLiftPercentage = 0x05;
}

class DoorLock {
  static const lockState = 0x0000;

  static const lockDoor = 0x00;
  static const unlockDoor = 0x01;
}

class Thermostat {
  static const localTemperature = 0x0000;
  static const occupiedCoolingSetpoint = 0x0011;
  static const occupiedHeatingSetpoint = 0x0012;
  static const systemMode = 0x001c;

  /// SystemMode values.
  static const modeOff = 0;
  static const modeAuto = 1;
  static const modeCool = 3;
  static const modeHeat = 4;
}

class FanControl {
  static const fanMode = 0x0000;
  static const percentSetting = 0x0002;
  static const percentCurrent = 0x0003;
}

/// Measured values of the sensor clusters are attribute 0.
const measuredValue = 0x0000;

/// Device types (Matter device library).
class DeviceType {
  static const rootNode = 0x0016;
  static const powerSource = 0x0011;
  static const aggregator = 0x000e;
  static const bridgedNode = 0x0013;
  static const onOffLight = 0x0100;
  static const dimmableLight = 0x0101;
  static const colorTemperatureLight = 0x010c;
  static const extendedColorLight = 0x010d;
  static const onOffPlugInUnit = 0x010a;
  static const dimmablePlugInUnit = 0x010b;
  static const mountedOnOffControl = 0x010f;
  static const mountedDimmableLoadControl = 0x0110;
  static const onOffLightSwitch = 0x0103;
  static const dimmerSwitch = 0x0104;
  static const genericSwitch = 0x000f;
  static const contactSensor = 0x0015;
  static const lightSensor = 0x0106;
  static const occupancySensor = 0x0107;
  static const temperatureSensor = 0x0302;
  static const pressureSensor = 0x0305;
  static const humiditySensor = 0x0307;
  static const waterLeakDetector = 0x0043;
  static const windowCovering = 0x0202;
  static const doorLock = 0x000a;
  static const thermostat = 0x0301;
  static const fan = 0x002b;
  static const airPurifier = 0x002d;
  static const roomAirConditioner = 0x0072;
  static const speaker = 0x0022;
  static const basicVideoPlayer = 0x0028;

  static String name(int t) =>
      const {
        0x0016: 'Root node',
        0x0011: 'Power source',
        0x000e: 'Bridge',
        0x0013: 'Bridged device',
        0x0100: 'Light',
        0x0101: 'Dimmable light',
        0x010c: 'White spectrum light',
        0x010d: 'Colour light',
        0x010a: 'Plug',
        0x010b: 'Dimmable plug',
        0x010f: 'Switch',
        0x0110: 'Dimmer',
        0x0103: 'Light switch',
        0x0104: 'Dimmer switch',
        0x000f: 'Button',
        0x0015: 'Contact sensor',
        0x0106: 'Light sensor',
        0x0107: 'Motion sensor',
        0x0302: 'Temperature sensor',
        0x0305: 'Pressure sensor',
        0x0307: 'Humidity sensor',
        0x0043: 'Leak sensor',
        0x0202: 'Blind',
        0x000a: 'Lock',
        0x0301: 'Thermostat',
        0x002b: 'Fan',
        0x002d: 'Air purifier',
        0x0072: 'Air conditioner',
        0x0022: 'Speaker',
        0x0028: 'TV',
      }[t] ??
      'Matter device';
}
