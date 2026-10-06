/// Public keys shared by the optional app service and the complete settings reset.
public enum ClipboardSyncSettingsStore {
  public static var enabledKey: String { DefaultsKey.clipboardSyncEnabled.key }
  public static var deviceKey: String { DefaultsKey.clipboardSyncDeviceID.key }
}
