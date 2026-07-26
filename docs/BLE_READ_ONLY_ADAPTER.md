# 安全只读 BLE 适配器

`NinebotBLETransport` 已提供扫描、已信任外设连接、服务/特征发现、Notify/Indicate 订阅、最多三次退避重连，以及把已解码遥测送至 `NinebotViewModel.ingestBLETelemetry(_:)` 的基础链路。

它**没有**并且不会提供以下能力：私有协议猜测、密钥提取、账户/蓝牙钥匙伪造、写特征、锁车/解锁/鸣笛控制、OTA。

## 接入前置条件

必须从厂商授权的 SDK、GATT 文档或已获许可的测试接口获得以下信息：

1. 指定车型和固件可用的 service UUID；
2. 每个只读 Notify / Indicate 遥测 characteristic UUID；
3. 已在合法绑定流程中确认的 `CBPeripheral.identifier`；
4. 经厂商授权的帧解析规则，以及该规则映射到 `NinebotBLETelemetry` 的字段定义。

请不要把密码、蓝牙钥匙、挑战响应材料、token 或固件包写入 profile、UserDefaults 或源码。

## 安装适配器

在拥有授权信息的集成层中调用：

```swift
let profile = NinebotBLEReadOnlyProfile(
    vehicleSN: vehicleSN,
    serviceUUIDStrings: authorizedServiceUUIDs,
    telemetryCharacteristicUUIDStrings: authorizedTelemetryUUIDs,
    trustedPeripheralIdentifier: approvedPeripheralIdentifier
)

model.configureAuthorizedBLEReadOnlyProfile(profile) { packet in
    // 仅使用厂商授权的解析器；失败时返回 nil。
    authorizedTelemetryDecoder.decode(packet)
}
model.connectAuthorizedBLEVehicle()
```

`trustedPeripheralIdentifier` 缺失时，模块可扫描候选设备，但会拒绝连接。即使 profile 完整，模块也只会订阅声明的 Notify / Indicate 特征，绝不会写入特征。

## 实时页面接入

解码器产出的 `NinebotBLETelemetry` 会自动进入现有 `NinebotViewModel.ingestBLETelemetry(_:)`，进而更新骑行 Live Activity、充电/静态状态、防盗遥测和通知逻辑。车辆位置仍由现有服务端或手机定位流程提供；BLE 基础层不会伪造 GPS 数据。
