enum DeviceTrustStatus {
  unknown,
  trusted,
  untrusted,
  pairingInProgress,
}

/// Represents an iOS physical device discovered over usbmuxd (USB port 27015).
class IosDeviceInfo {
  final int deviceId;
  final String serialNumber; // UDID
  final String connectionType;
  final int connectionSpeed;
  final String deviceName;
  final String productType;
  final DeviceTrustStatus trustStatus;

  const IosDeviceInfo({
    required this.deviceId,
    required this.serialNumber,
    this.connectionType = 'USB',
    this.connectionSpeed = 480000000,
    this.deviceName = 'iOS Device',
    this.productType = 'iPhone',
    this.trustStatus = DeviceTrustStatus.unknown,
  });

  factory IosDeviceInfo.fromMap(Map<dynamic, dynamic> map) {
    DeviceTrustStatus parseTrust(dynamic val) {
      if (val == 'trusted' || val == 1 || val == true) {
        return DeviceTrustStatus.trusted;
      }
      if (val == 'untrusted' || val == 0) {
        return DeviceTrustStatus.untrusted;
      }
      if (val == 'pairing') {
        return DeviceTrustStatus.pairingInProgress;
      }
      return DeviceTrustStatus.unknown;
    }

    return IosDeviceInfo(
      deviceId: map['deviceId'] is int
          ? map['deviceId'] as int
          : int.tryParse(map['deviceId']?.toString() ?? '0') ?? 0,
      serialNumber: map['serialNumber']?.toString() ?? '',
      connectionType: map['connectionType']?.toString() ?? 'USB',
      connectionSpeed: map['connectionSpeed'] is int
          ? map['connectionSpeed'] as int
          : int.tryParse(map['connectionSpeed']?.toString() ?? '0') ?? 480000000,
      deviceName: map['deviceName']?.toString() ?? 'iPhone',
      productType: map['productType']?.toString() ?? 'iOS Device',
      trustStatus: parseTrust(map['trustStatus']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'deviceId': deviceId,
      'serialNumber': serialNumber,
      'connectionType': connectionType,
      'connectionSpeed': connectionSpeed,
      'deviceName': deviceName,
      'productType': productType,
      'trustStatus': trustStatus.name,
    };
  }

  IosDeviceInfo copyWith({
    int? deviceId,
    String? serialNumber,
    String? connectionType,
    int? connectionSpeed,
    String? deviceName,
    String? productType,
    DeviceTrustStatus? trustStatus,
  }) {
    return IosDeviceInfo(
      deviceId: deviceId ?? this.deviceId,
      serialNumber: serialNumber ?? this.serialNumber,
      connectionType: connectionType ?? this.connectionType,
      connectionSpeed: connectionSpeed ?? this.connectionSpeed,
      deviceName: deviceName ?? this.deviceName,
      productType: productType ?? this.productType,
      trustStatus: trustStatus ?? this.trustStatus,
    );
  }
}
