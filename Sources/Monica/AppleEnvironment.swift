import Foundation

/// The device, OS and application facts MONICA attaches to every event.
///
/// Only values that describe the build of the device and of the application
/// are collected. Nothing here identifies an individual install or person: no
/// `identifierForVendor`, device name, advertising id, account, or location.
/// Anything about the user is the application's call and travels through
/// `setUser` or `beforeSend`.
public struct AppleEnvironment: Equatable {
  public var deviceModel: String?
  public var isSimulator: Bool
  public var osName: String
  public var osVersion: String
  public var appIdentifier: String?
  public var appVersion: String?
  public var appBuild: String?
  /// `CFBundleExecutable`: the binary image whose frames are `in_app` by default.
  public var executableName: String?

  public init(deviceModel: String?, isSimulator: Bool, osName: String, osVersion: String,
              appIdentifier: String?, appVersion: String?, appBuild: String?, executableName: String?) {
    self.deviceModel = deviceModel
    self.isSimulator = isSimulator
    self.osName = osName
    self.osVersion = osVersion
    self.appIdentifier = appIdentifier
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.executableName = executableName
  }

  public static func current(bundle: Bundle = .main) -> AppleEnvironment {
    let info = bundle.infoDictionary ?? [:]
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
    return AppleEnvironment(
      deviceModel: simulatorModel ?? hardwareModel(),
      isSimulator: simulatorModel != nil,
      osName: osName,
      osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
      appIdentifier: bundle.bundleIdentifier,
      appVersion: info["CFBundleShortVersionString"] as? String,
      appBuild: info["CFBundleVersion"] as? String,
      executableName: info["CFBundleExecutable"] as? String
        ?? bundle.executableURL?.lastPathComponent
    )
  }

  static var osName: String {
    #if os(iOS)
    return "iOS"
    #elseif os(tvOS)
    return "tvOS"
    #elseif os(watchOS)
    return "watchOS"
    #elseif os(visionOS)
    return "visionOS"
    #elseif os(macOS)
    return "macOS"
    #else
    return "unknown"
    #endif
  }

  /// `iPhone15,2` and friends: the hardware identifier, not the user's device name.
  static func hardwareModel() -> String? {
    var system = utsname()
    guard uname(&system) == 0 else { return nil }
    return withUnsafePointer(to: &system.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
    }
  }

  /// Writes the device, os and app contexts onto a scope shared by every event.
  public func apply(to scope: Scope) {
    var device: [String: Any] = ["manufacturer": "Apple"]
    if let model = deviceModel, !model.isEmpty { device["model"] = model }
    if isSimulator { device["simulator"] = true }
    scope.setContext("device", device)
    scope.setContext("os", ["name": osName, "version": osVersion])
    var app: [String: Any] = [:]
    if let identifier = appIdentifier, !identifier.isEmpty { app["app_identifier"] = identifier }
    if let version = appVersion, !version.isEmpty { app["app_version"] = version }
    if let build = appBuild, !build.isEmpty { app["app_build"] = build }
    if !app.isEmpty { scope.setContext("app", app) }
  }
}
