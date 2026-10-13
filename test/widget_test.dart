import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:applecast/main.dart';
import 'package:applecast/models/device_info.dart';
import 'package:applecast/models/stream_metrics.dart';
import 'package:applecast/ui/widgets/device_card.dart';
import 'package:applecast/ui/widgets/telemetry_hud.dart';

void main() {
  testWidgets('AppleCast app initialization smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AppleCastApp());
    expect(find.text('AppleCast'), findsOneWidget);
    expect(find.text('Wired USB Mirroring Studio'), findsOneWidget);
  });

  testWidgets('DeviceCard displays device information and trust badge', (WidgetTester tester) async {
    const testDevice = IosDeviceInfo(
      deviceId: 3,
      serialNumber: '00008110-00192C2E1160401E',
      deviceName: "Viraj's iPhone",
      productType: 'iPhone 15 Pro',
      connectionSpeed: 480000000,
      trustStatus: DeviceTrustStatus.trusted,
    );

    bool connectTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DeviceCard(
            device: testDevice,
            isSelected: true,
            isMirroring: false,
            onSelect: () {},
            onConnect: () => connectTapped = true,
            onDisconnect: () {},
            onRequestTrust: () {},
          ),
        ),
      ),
    );

    expect(find.text("Viraj's iPhone"), findsOneWidget);
    expect(find.text('iPhone 15 Pro'), findsOneWidget);
    expect(find.text('Trusted'), findsOneWidget);
    expect(find.text('Mirror'), findsOneWidget);

    await tester.tap(find.text('Mirror'));
    expect(connectTapped, isTrue);
  });

  testWidgets('TelemetryHud renders real-time stream metrics', (WidgetTester tester) async {
    const metrics = StreamMetrics(
      fps: 60.0,
      bitrateMbps: 15.2,
      latencyMs: 11.4,
      width: 1920,
      height: 1080,
      codec: 'H.264 / D3D11VA',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TelemetryHud(metrics: metrics),
        ),
      ),
    );

    expect(find.text('FPS'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('11.4 ms'), findsOneWidget);
    expect(find.text('15.2 Mbps'), findsOneWidget);
    expect(find.text('H.264 / D3D11VA'), findsOneWidget);
    expect(find.text('1920x1080'), findsOneWidget);
  });
}
