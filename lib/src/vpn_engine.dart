import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

/// Stages of VPN connections
enum VPNStage {
  prepare,
  authenticating,
  connecting,
  authentication,
  connected,
  disconnected,
  disconnecting,
  denied,
  error,
  wait_connection,
  vpn_generate_config,
  get_config,
  tcp_connect,
  udp_connect,
  assign_ip,
  resolve,
  exiting,
  unknown
}

class OpenVPNService {
  /// Channel's names of _vpnStageSnapshot
  static const String _eventChannelVpnStage =
      "id.laskarmedia.openvpn_flutter/vpnstage";

  /// Channel's names of _channelControl
  static const String _methodChannelVpnControl =
      "id.laskarmedia.openvpn_flutter/vpncontrol";

  /// Method channel to invoke methods from native side
  static const MethodChannel _channelControl =
  MethodChannel(_methodChannelVpnControl);

  /// Snapshot of stream that produced by native side
  static Stream<String> _vpnStageSnapshot() =>
      const EventChannel(_eventChannelVpnStage).receiveBroadcastStream().cast();

  /// Timer to get VPN status as a loop
  ///
  /// I know it was bad practice, but this is the only way to avoid Android status duration having long delay
  Timer? _vpnStatusTimer;

  /// To indicate the engine already initialize
  bool initialized = false;

  /// Use tempDateTime to countdown, especially on Android that has delays
  DateTime? _tempDateTime;

  VPNStage? _lastStage;

  /// is a listener to see VPN status detail
  final Function(VpnStatus? data)? onVpnStatusChanged;

  /// is a listener to see what stage the connection was
  final Function(VPNStage stage, String rawStage)? onVpnStageChanged;

  /// OpenVPN's Constructions, don't forget to implement the listeners
  /// onVpnStatusChanged is a listener to see VPN status detail
  /// onVpnStageChanged is a listener to see what stage the connection was
  OpenVPNService({this.onVpnStatusChanged, this.onVpnStageChanged});

  /// This function should be called before any usage of OpenVPN
  /// All params required for iOS, make sure you read the plugin's documentation

  /// providerBundleIdentfier is for your Network Extension identifier

  /// localizedDescription is for description to show in user's settings

  /// Will return latest VPNStage
  Future<void> initialize({
    String? providerBundleIdentifier,
    String? localizedDescription,
    String? groupIdentifier,
    Function(VpnStatus status)? lastStatus,
    Function(VPNStage stage)? lastStage,
  }) async {
    if (Platform.isIOS) {
      assert(
      groupIdentifier != null &&
          providerBundleIdentifier != null &&
          localizedDescription != null,
      "These values are required for iOS.");
    }
    onVpnStatusChanged?.call(VpnStatus.empty());
    initialized = true;
    _initializeListener();
    return _channelControl.invokeMethod("initialize", {
      "groupIdentifier": groupIdentifier,
      "providerBundleIdentifier": providerBundleIdentifier,
      "localizedDescription": localizedDescription,
    }).then((value) {
      Future.wait([
        status().then((value) => lastStatus?.call(value)),
        stage().then((value) {
          return lastStage?.call(value);
        }),
      ]);
    });
  }

  /// Connect to VPN

  /// config : Your OpenVPN configuration script, you can find it inside your .ovpn file

  /// name : name that will show in user's notification

  /// certIsRequired : default is false, if your config file has cert, set it to true

  /// username & password : set your username and password if your config file has auth-user-pass

  /// bypassPackages : exclude some apps to access/use the VPN Connection, it was List<String> of applications package's name (Android Only)

  void connect(String config, String name,
      {String? username,
        String? password,
        List<String>? bypassPackages,
        bool certIsRequired = false}) async {
    if (!initialized) throw ("OpenVPN needs to be initialized");
    if (!certIsRequired) config += "client-cert-not-required";
    _channelControl.invokeMethod("connect", {
      "config": config,
      "name": name,
      "username": username,
      "password": password,
      "bypass_packages": bypassPackages ?? []
    });
  }

  /// Disconnect from VPN
  void disconnect() {
    _tempDateTime = null;
    _channelControl.invokeMethod("disconnect");
    if (_vpnStatusTimer?.isActive ?? false) {
      _vpnStatusTimer?.cancel();
      _vpnStatusTimer = null;
    }
  }

  /// Check if connected to VPN
  Future<bool> isConnected() async =>
      stage().then((value) => value == VPNStage.connected);

  /// Get latest connection stage
  Future<VPNStage> stage() async {
    String? stage = await _channelControl.invokeMethod("stage");
    return _strToStage(stage ?? "disconnected");
  }

  /// Get latest connection status
  Future<VpnStatus> status() {
    // Have to check if user is already connected to get real data
    return stage().then((value) async {
      var status = VpnStatus.empty();
      if (value == VPNStage.connected) {
        status = await _channelControl.invokeMethod("status").then((value) {
          if (value == null) return VpnStatus.empty();

          if (Platform.isIOS) {
            var splitted = value.split("_");
            var connectedOn = DateTime.tryParse(splitted[0]);
            if (connectedOn == null) return VpnStatus.empty();
            return VpnStatus(
              connectedOn: connectedOn,
              duration: _duration(DateTime.now().difference(connectedOn).abs()),
              packetsIn: splitted[1],
              packetsOut: splitted[2],
              byteIn: splitted[3],
              byteOut: splitted[4],
            );
          } else if (Platform.isAndroid) {
            var data = jsonDecode(value);
            var connectedOn =
                DateTime.tryParse(data["connected_on"].toString()) ??
                    _tempDateTime;
            if (connectedOn == null) return VpnStatus.empty();
            String byteIn =
            data["byte_in"] != null ? data["byte_in"].toString() : "0";
            String byteOut =
            data["byte_out"] != null ? data["byte_out"].toString() : "0";
            if (byteIn.trim().isEmpty) byteIn = "0";
            if (byteOut.trim().isEmpty) byteOut = "0";
            return VpnStatus(
              connectedOn: connectedOn,
              duration: _duration(DateTime.now().difference(connectedOn).abs()),
              byteIn: byteIn,
              byteOut: byteOut,
              packetsIn: byteIn,
              packetsOut: byteOut,
            );
          } else {
            throw Exception("OpenVPN not supported on this platform");
          }
        });
      }
      return status;
    });
  }

  /// Request Android permission (Return true if already granted)
  Future<bool> requestPermissionAndroid() async {
    return _channelControl
        .invokeMethod("request_permission")
        .then((value) => value ?? false);
  }

  /// Sometimes config script has too many Remotes, it causes ANR in several devices,
  /// This happens because the plugin checks every remote and somehow affects the UI to freeze
  ///
  /// Use this function if you want to force the user to use 1 remote by randomizing the remotes provided
  static Future<String?> filteredConfig(String? config) async {
    List<String> remotes = [];
    List<String> output = [];
    if (config == null) return null;
    var raw = config.split("\n");

    for (var item in raw) {
      if (item.trim().toLowerCase().startsWith("remote ")) {
        if (!output.contains("REMOTE_HERE")) {
          output.add("REMOTE_HERE");
        }
        remotes.add(item);
      } else {
        output.add(item);
      }
    }
    String fastestServer = remotes[Random().nextInt(remotes.length - 1)];
    int indexRemote = output.indexWhere((element) => element == "REMOTE_HERE");
    output.removeWhere((element) => element == "REMOTE_HERE");
    output.insert(indexRemote, fastestServer);
    return output.join("\n");
  }

  /// Convert duration that produced by native side as Connection Time
  String _duration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  /// Private function to convert String to VPNStage
  static VPNStage _strToStage(String? stage) {
    if (stage == null ||
        stage.trim().isEmpty ||
        stage.trim() == "idle" ||
        stage.trim() == "invalid") {
      return VPNStage.disconnected;
    }
    var indexStage = VPNStage.values.indexWhere((element) => element
        .toString()
        .trim()
        .toLowerCase()
        .contains(stage.toString().trim().toLowerCase()));
    if (indexStage >= 0) return VPNStage.values[indexStage];
    return VPNStage.unknown;
  }

  /// Initialize listener, called when you start connection and stopped while
  void _initializeListener() {
    _vpnStageSnapshot().listen((event) {
      var vpnStage = _strToStage(event);
      if (vpnStage != _lastStage) {
        onVpnStageChanged?.call(vpnStage, event);
        _lastStage = vpnStage;
      }
      if (vpnStage == VPNStage.connected) {
        _tempDateTime = DateTime.now(); // Update tempDateTime when connected
        _createTimer();
      } else if (vpnStage == VPNStage.disconnected) {
        _vpnStatusTimer?.cancel();
        _vpnStatusTimer = null;
      }
    });
  }

  /// Create timer to invoke status
  void _createTimer() {
    if (_vpnStatusTimer != null) {
      _vpnStatusTimer!.cancel();
      _vpnStatusTimer = null;
    }
    _vpnStatusTimer ??=
        Timer.periodic(const Duration(seconds: 1), (timer) async {
          onVpnStatusChanged?.call(await status());
        });
  }
}
