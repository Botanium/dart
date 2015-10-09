/// A library to manage launching application.
library atom.launch;

import 'dart:async';

import 'package:logging/logging.dart';

import 'atom.dart';
import 'atom_utils.dart';
import 'projects.dart';
import 'state.dart';
import 'utils.dart';

final Logger _logger = new Logger('atom.launch');

class LaunchManager implements Disposable {
  StreamController<Launch> _launchAdded = new StreamController.broadcast(sync: true);
  StreamController<Launch> _launchActivated = new StreamController.broadcast();
  StreamController<Launch> _launchTerminated = new StreamController.broadcast();
  StreamController<Launch> _launchRemoved = new StreamController.broadcast();

  List<LaunchType> launchTypes = [];

  Launch _activeLaunch;
  final List<Launch> _launches = [];

  List<LaunchConfiguration> _configs;

  LaunchManager() {
    _readConfigs();
  }

  Launch get activeLaunch => _activeLaunch;

  List<Launch> get launches => _launches;

  void addLaunch(Launch launch) {
    _launches.add(launch);
    bool activated = false;

    // Automatically remove all dead launches.
    List removed = [];
    _launches.removeWhere((l) {
      if (l.isTerminated) {
        if (_activeLaunch == l) _activeLaunch = null;
        removed.add(l);
      }
      return l.isTerminated;
    });

    if (_activeLaunch == null) {
      _activeLaunch = launch;
      activated = true;
    }

    removed.forEach((l) => _launchRemoved.add(l));
    _launchAdded.add(launch);
    if (activated) _launchActivated.add(launch);
  }

  void setActiveLaunch(Launch launch) {
    if (launch != _activeLaunch) {
      _activeLaunch = launch;
      _launchActivated.add(_activeLaunch);
    }
  }

  void removeLaunch(Launch launch) {
    _launches.remove(launch);
    bool activeChanged = false;
    if (launch == _activeLaunch) {
      _activeLaunch = null;
      if (_launches.isNotEmpty) _activeLaunch = launches.first;
      activeChanged = true;
    }

    _launchRemoved.add(launch);
    if (activeChanged) _launchActivated.add(_activeLaunch);
  }

  Stream<Launch> get onLaunchAdded => _launchAdded.stream;
  Stream<Launch> get onLaunchActivated => _launchActivated.stream;
  Stream<Launch> get onLaunchTerminated => _launchTerminated.stream;
  Stream<Launch> get onLaunchRemoved => _launchRemoved.stream;

  void registerLaunchType(LaunchType type) {
    launchTypes.remove(type);
    launchTypes.add(type);
  }

  List<String> getLaunchTypes() => launchTypes.map((l) => l.type).toList()..sort();

  /// Get the best launch handler for the given resource; return `null`
  /// otherwise.
  LaunchType getHandlerFor(String path) {
    for (LaunchType type in launchTypes) {
      if (type.canLaunch(path)) return type;
    }
    return null;
  }

  LaunchType getLaunchType(String typeCode) {
    for (LaunchType type in launchTypes) {
      if (type.type == typeCode) return type;
    }
    return null;
  }

  void _readConfigs() {
    var savedConfigs = state['launchConfigs'];

    // TODO: This is not being restored as a List.
    if (savedConfigs is List) {
      _configs = savedConfigs.map((Map json) {
        try {
          return new LaunchConfiguration.from(json);
        } catch (e) {
          _logger.warning('Error restoring launch config', e);
          return null;
        }
      }).where((config) => config != null).toList();

      _logger.info('Restored ${_configs} launch configurations.');
    } else {
      state['launchConfigs'] = [];
      _configs = [];
    }
  }

  void createConfiguration(LaunchConfiguration config) {
    _configs.add(config);
    (state['launchConfigs'] as List).add(config.getStorableMap());
  }

  List<LaunchConfiguration> getAllConfigurations() => _configs;

  List<LaunchConfiguration> getConfigurationsForPath(String path) {
    return _configs.where((LaunchConfiguration config) {
      return config.primaryResource == path;
    }).toList();
  }

  List<LaunchConfiguration> getConfigurationsForProject(DartProject project) {
    String path = '${project.path}${separator}';

    return _configs.where((LaunchConfiguration config) {
      String r = config.primaryResource;
      return r != null && r.startsWith(path);
    }).toList();
  }

  void deleteConfiguration(LaunchConfiguration config) {
    if (_configs.remove(config)) {
      (state['launchConfigs'] as List).remove(config.getStorableMap());
    }
  }

  void dispose() {
    for (Launch launch in _launches.toList()) {
      launch.dispose();
    }
  }
}

/// A general type of launch, like a command-line launch or a web launch.
abstract class LaunchType {
  final String type;

  LaunchType(this.type);

  bool canLaunch(String path);

  List<String> getLaunchablesFor(DartProject project);

  LaunchConfiguration createConfiguration(String path) {
    return new LaunchConfiguration(this, primaryResource: path);
  }

  Future<Launch> performLaunch(LaunchManager manager, LaunchConfiguration configuration);

  operator== (obj) => obj is LaunchType && obj.type == type;
  int get hashCode => type.hashCode;
  String toString() => type;
}

/// A configuration for a particular launch type.
class LaunchConfiguration {
  Map<String, dynamic> _config = {};

  LaunchConfiguration(LaunchType launchType, {String primaryResource}) {
    if (launchType != null) _config['launchType'] = launchType.type;
    if (primaryResource != null) this.primaryResource = primaryResource;
    touch();
  }

  LaunchConfiguration.from(this._config);

  String get launchType => _config['launchType'];

  String get cwd => _config['cwd'];
  set cwd(String value) {
    _config['cwd'] = value;
  }

  String get primaryResource => _config['primary'];
  set primaryResource(String value) {
    _config['primary'] = value;
  }

  String get args => _config['args'];
  set args(String value) {
    _config['args'] = value;
  }

  List<String> get argsAsList {
    String str = args;
    // TODO: Handle args wrapped by quotes.
    return str == null ? null : str.split(' ');
  }

  /// Used when persisting the `LaunchConfiguration`.
  Map getStorableMap() => _config;

  /// Update the timestamp for this launch configuration.
  void touch() {
    _config['timestamp'] = new DateTime.now().millisecondsSinceEpoch;
  }

  /// Get the last launch time.
  int get timestamp => _config['timestamp'];

  String toString() => primaryResource;
}

/// The instantiation of something that was launched.
class Launch implements Disposable {
  static int _id = 0;

  final LaunchType launchType;
  final String title;
  final LaunchManager manager;
  final int id = ++_id;
  final Function killHandler;

  int servicePort;

  StreamController<String> _stdout = new StreamController.broadcast();
  StreamController<String> _stderr = new StreamController.broadcast();

  int _exitCode;

  Launch(this.launchType, this.title, this.manager, {this.killHandler});

  int get exitCode => _exitCode;
  bool get errored => _exitCode != null && _exitCode != 0;

  bool get isRunning => _exitCode == null;
  bool get isTerminated => _exitCode != null;

  bool get isActive => manager.activeLaunch == this;

  Stream<String> get onStdout => _stdout.stream;
  Stream<String> get onStderr => _stderr.stream;

  void pipeStdout(String str) => _stdout.add(str);
  void pipeStderr(String str) => _stderr.add(str);

  bool canDebug() => isRunning && servicePort != null;

  bool canKill() => killHandler != null;

  Future kill() {
    if (killHandler != null) {
      var f = killHandler();
      return f is Future ? f : new Future.value();
    } else {
      return new Future.value();
    }
  }

  void launchTerminated(int exitCode) {
    if (_exitCode != null) return;
    _exitCode = exitCode;

    if (errored) {
      atom.notifications.addError('${this} exited with error code ${exitCode}.');
    } else {
      atom.notifications.addSuccess('${this} finished.');
    }

    manager._launchTerminated.add(this);
  }

  void dispose() {
    if (canKill() && !isRunning) {
      kill();
    }
  }

  String toString() => '${launchType}: ${title}';
}