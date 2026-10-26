import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'app_theme.dart';
import 'core_bridge.dart';
import 'danmaku_controller.dart';
import 'danmaku_overlay.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'playback_preferences.dart';
import 'player_controls.dart';
import 'player_interactions.dart';
import 'player_menu.dart';
import 'television_controls.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'lan_controller.dart';
import 'lan_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController? _video;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  bool _preloadEnabled = true;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  bool _danmakuEnabled = true;
  late final PlayerInteractions _interactions;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  double? _lanFirstPosition;
  String? _savedProgressKey;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  bool _panelOpen = false;
  bool _autoAdvance = true;
  bool? _systemFullscreen;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;
  bool _pendingError = false;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  double _resumePosition = 0;
  bool _rotating = false;
  bool _television = false;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  PlaybackPreferences get _preferences => PlaybackPreferences(
        speed: _speed,
        quality: _requestedQuality,
        autoAdvance: _autoAdvance,
        danmaku: _danmakuEnabled,
        preload: _preloadEnabled,
      );
  String get _qualityLabel => _plan?.local == true
      ? '本地原画'
      : _requestedQuality == 0
          ? '自动'
          : '${_requestedQuality}P';
  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _openedIndex == _index && _player.state.position.inMilliseconds > 0
          ? _player.state.position.inMilliseconds / 1000
          : _resumePosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _requestedQuality = preferences.quality;
    _autoAdvance = preferences.autoAdvance;
    _danmakuEnabled = preferences.danmaku;
    _preloadEnabled = preferences.preload;
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _player = widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            bufferSize: 32 * 1024 * 1024,
          ),
        );
    _video = widget.videoBuilder == null ? VideoController(_player) : null;
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _rotate,
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= widget.detail.episodes.length) return '已经是最后一集';
        unawaited(_play(next));
        return '第 ${widget.detail.episodes[next].number} 集';
      },
    );
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          if (duration <= Duration.zero ||
              _player.state.position < duration - const Duration(seconds: 2)) {
            _queueRecovery();
          } else if (_autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _index + 1 < widget.detail.episodes.length) {
            _play(_index + 1);
          } else {
            _playIntent = false;
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress(flush: true));
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        _syncDanmaku();
        _syncPreload();
        _acknowledgeHandoff();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final width = parameters.dw ?? parameters.w ?? 0;
        final height = parameters.dh ?? parameters.h ?? 0;
        if (width > 0 && height > 0 && mounted && !_closed) {
          setState(() {
            _aspectRatio = width / height;
          });
          _scheduleSystemUi();
        }
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _player.state.playing && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null)
        unawaited(widget.repository.release(handoff.plan.session));
      _loading = false;
      _error = '播放接收已取消';
    } else {
      _play(
        _index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
      }
    });
  }

  void _accessChanged() {
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _preloader.clear();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail('接收端用户已变更');
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource('hongguo'))) {
      _danmaku.setPlan(null);
    }
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title: widget.detail.drama.title +
            ' · 第 ' +
            widget.detail.episodes[_index].number.toString() +
            ' 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch) return;
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20) return;
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _generation;
    await _serialize(() async {
      if (_closed ||
          generation != _generation ||
          widget.store.profileEpoch != _profileEpoch) return;
      _playIntent = false;
      _interactions.cancel();
      _health.reset();
      await _player.pause();
      await _saveProgress(flush: true);
    });
  }

  Future<void> _pushToDevice() async {
    final link = LanController.current;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null) return;
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _generation &&
        index == _index &&
        widget.store.profileEpoch == _profileEpoch;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    if (duration <= 0 ||
        position < 2000 ||
        (position < duration ~/ 2 && duration - position > 45000) ||
        state.buffer.inMilliseconds - position < 5000) {
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
    );
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available: !_loading &&
          _error == null &&
          _openedIndex == _index &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _television = AppLayout.isTelevision(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncDanmaku();
    _syncPreload();
    _health.reset();
    if (!_foreground) _interactions.cancel();
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _playIntent = false;
      _player.pause();
      _saveProgress(flush: true);
    }
    if (_foreground && _pendingError) {
      _queueRecovery();
    }
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action =
        current.local ? PlaybackRecoveryAction.stop : _recovery.next(current);
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _player.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _localFailure = current.local;
          _error = current.local
              ? widget.allowOnlineFallback
                  ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                  : '本地成品读取失败，请重试或重新生成。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
      }
      return;
    }
    await _play(_index, position: position, recoveryAction: action);
  }

  void _togglePlayback() {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已操作播放');
    _interactions.cancel();
    _playIntent = !_player.state.playing;
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_player.playOrPause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
    _syncDanmaku();
  }

  Future<void> _saveProgress({bool flush = false}) async {
    if (_openedIndex < 0 || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final position = _player.state.position.inMilliseconds / 1000;
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex:$position:$duration';
    if (_savedProgressKey == progressKey && _saveWarning == null) {
      if (flush && widget.mediaId == null) LanController.current?.flush();
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(entry);
        if (flush) LanController.current?.flush();
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
      _savedProgressKey = progressKey;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看进度尚未保存，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
  }) async {
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail('接收端已更换播放内容');
    }
    if (index != _index) _forceOnline = false;
    final warmed = handoffPlan ??
        (recoveryAction == null && _preloadEnabled && !widget.localOnly
            ? _preloader.take(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _requestedQuality,
                online: _forceOnline,
              )
            : null);
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
        _ => '正在准备播放',
      };
    });
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress(flush: true);
        _openedIndex = -1;
        await _player.stop();
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative) {
          retained = previous;
        } else if (previous != null) {
          await widget.repository.release(previous.session);
        }
      });
      if (_closed || ticket != _generation) {
        return;
      }
      prepared = retained != null
          ? await _loader.fallback(retained!)
          : warmed != null
              ? await _loader.use(warmed)
              : await _loader.load(
                  widget.detail.drama,
                  widget.detail.episodes[index],
                  quality: _requestedQuality,
                  localOnly: widget.localOnly,
                  online: _forceOnline,
                );
      if (prepared == null) {
        return;
      }
      final plan = prepared;
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              'seg_max_retry=3',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          await platform.setProperty('network-timeout', '20');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
        if (_closed || ticket != _generation) {
          return;
        }
        _openedIndex = index;
        _attachLanPlayback();
        _health.reset();
        await _interactions.applySpeed();
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
          });
          _danmaku.setPlan(plan);
          _syncDanmaku();
          _acknowledgeHandoff();
          _menuRevision.value++;
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                      (widget.localOnly && !_forceOnline);
              _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
              widget.handoff?.fail(_error!);
            });
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _player.state.playing,
    );
  }

  bool get _showFullscreen =>
      _television ||
      _fullscreen ||
      (_mobile &&
          !_automaticFullscreenSuppressed &&
          _aspectRatio >= 1 &&
          MediaQuery.orientationOf(context) == Orientation.landscape);

  Future<void> _rotate() async {
    if (_rotating || _television) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      if (Platform.isWindows) {
        await windowManager.setFullScreen(fullscreen);
      } else if (_mobile) {
        if (fullscreen) {
          await SystemChrome.setPreferredOrientations(
            _aspectRatio >= 1
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ]
                : [
                    DeviceOrientation.portraitUp,
                    DeviceOrientation.portraitDown,
                  ],
          );
        } else {
          await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        }
      }
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    await widget.store.setPlaybackPreferences(preferences);
    if (!mounted || _closed) return;
    final qualityChanged = preferences.quality != _requestedQuality;
    setState(() {
      _speed = preferences.speed;
      _requestedQuality = preferences.quality;
      _autoAdvance = preferences.autoAdvance;
      _danmakuEnabled = preferences.danmaku;
      _preloadEnabled = preferences.preload;
    });
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged || !_preloadEnabled) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _plan?.local != true) {
      await _retry(quality: preferences.quality);
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
    } catch (_) {
      _notice('追剧记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      final index = await showDialog<int>(
        context: context,
        builder: (menuContext) => Theme(
          data: AppTheme.dark,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              _menuRevision,
              widget.store,
              _danmaku,
              _preloader,
            ]),
            builder: (context, child) => PlayerMenu(
              section: section,
              episodes: widget.detail.episodes,
              currentIndex: _index,
              preferences: _preferences,
              qualities: _plan?.qualities ?? [],
              actualQuality: _plan?.quality ?? 0,
              local: _plan?.local == true,
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              mobile: _mobile,
              onEpisode: (index) => Navigator.pop(menuContext, index),
              onPreferences: _setPreferences,
              showDanmaku: widget.detail.drama.source == 'hongguo',
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preloadStatus: _preloader.status,
              onFavorite: () =>
                  widget.store.toggleFavorite(widget.detail.drama),
            ),
          ),
        ),
      );
      if (mounted && !_closed && index != null && index != _index) {
        await _play(index);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    final ticket = ++_seekSequence;
    final generation = _generation;
    _danmaku.beginSeek();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
    } catch (_) {
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
      }
    }
  }

  void _seek(int seconds) {
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
            ? maxDuration
            : desired;
    unawaited(_seekTo(target));
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (_) => TelevisionEpisodeDialog(
          episodes: widget.detail.episodes,
          currentIndex: _index,
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (_) => AnimatedBuilder(
          animation: Listenable.merge([_danmaku, _preloader]),
          builder: (context, child) => TelevisionSettingsDialog(
            speed: _speed,
            quality: _requestedQuality,
            qualities: _plan?.qualities ?? [],
            favorite: widget.store.isFavorite(widget.detail.drama.id),
            onFavorite: _toggleFavorite,
            autoAdvance: _autoAdvance,
            danmaku: _danmakuEnabled,
            showDanmaku: widget.detail.drama.source == 'hongguo',
            danmakuStatus: _danmaku.status,
            onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
            preload: _preloadEnabled,
            preloadStatus: _preloader.status,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: selection.autoAdvance,
          danmaku: selection.danmaku,
          preload: selection.preload,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  void _back() {
    if (_showFullscreen && !_television) {
      _rotate();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _closed = true;
    LanController.current?.detachPlayback(_lanIdentity);
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _interactions.pendingRates.catchError((Object _) {});
        await _player.dispose();
      }),
    );
    if (Platform.isWindows) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile) {
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    } else if (_television && Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
        data: _television ? televisionTheme(AppTheme.dark) : AppTheme.dark,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: AppTheme.systemBars(Brightness.dark),
          child: Builder(builder: _buildPlayer),
        ),
      );

  Widget _buildPlayer(BuildContext context) {
    final title = widget.detail.drama.title;
    final episode = widget.detail.episodes[_index];
    final fullscreen = _showFullscreen;
    return PopScope(
      canPop: _television || !fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && fullscreen && !_television) {
          _rotate();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor: Colors.black,
            appBar: fullscreen
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    backgroundColor: const Color(0xFF101114),
                    actions: [
                      IconButton(
                        tooltip: '旋转与全屏',
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation_alt_rounded),
                      ),
                    ],
                  ),
            body: SafeArea(
              top: false,
              bottom: !fullscreen,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final desktop = constraints.maxWidth >= 840;
                  if (fullscreen) {
                    return _videoPane(context);
                  }
                  if (desktop ||
                      constraints.maxWidth > constraints.maxHeight * 1.3) {
                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: _videoPane(context)),
                              _actionBar(episode),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: desktop ? 312 : 210,
                          child: _episodePanel(),
                        ),
                      ],
                    );
                  }
                  final height = (constraints.maxWidth / _aspectRatio).clamp(
                    0.0,
                    constraints.maxHeight * .64,
                  );
                  return Column(
                    children: [
                      SizedBox(
                        height: height,
                        width: double.infinity,
                        child: _videoPane(context),
                      ),
                      _actionBar(episode),
                      Expanded(child: _episodePanel()),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _videoPane(BuildContext context) {
    final title =
        '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集${_plan?.local == true ? ' · 本地' : ''}${widget.detail.episodes[_index].vip ? ' · VIP 试看' : ''}${(_plan?.routeIndex ?? 0) > 0 ? ' · 线路 ${_plan!.routeIndex + 1}' : ''}';
    final Widget controls = _television
        ? TelevisionControls(
            player: _player,
            title: title,
            enabled: !_loading && _error == null,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onBack: _back,
            onPush: widget.mediaId == null ? _pushToDevice : null,
          )
        : PlayerControls(
            player: _player,
            interactions: _interactions,
            enabled: !_loading && _error == null,
            panelOpen: _panelOpen,
            fullscreen: _showFullscreen,
            title: title,
            onTogglePlayback: _togglePlayback,
            swipeEnabled: _mobile,
            onFullscreen: _rotate,
            onFocusSurface: _playerFocus.requestFocus,
            onSeek: _seekTo,
            speed: _speed,
            qualityLabel: _qualityLabel,
            onEpisodes: () => _openPanel(PlayerMenuSection.episodes),
            onSpeed: () => _openPanel(PlayerMenuSection.speed),
            onQuality: () => _openPanel(PlayerMenuSection.quality),
            onSettings: () => _openPanel(PlayerMenuSection.settings),
            onPush: widget.mediaId == null ? _pushToDevice : null,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
          );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        DanmakuOverlay(controller: _danmaku, aspectRatio: _aspectRatio),
        controls,
      ],
    );
    return Stack(
      key: _videoPaneKey,
      fit: StackFit.expand,
      children: [
        if (widget.videoBuilder != null)
          widget.videoBuilder!(layeredControls)
        else
          Video(
            controller: _video!,
            fit: BoxFit.contain,
            controls: (_) => layeredControls,
          ),
        if (_loading)
          ColoredBox(
            color: Colors.black.withValues(alpha: .78),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(_loadingMessage),
                ],
              ),
            ),
          ),
        if (_error != null)
          ColoredBox(
            color: Colors.black.withValues(alpha: .9),
            child: StatusPanel(
              title: '暂时无法播放',
              message: _error!,
              onRetry: () => _retry(),
              action: _localFailure ? '重试本地播放' : '重试播放',
              secondaryAction: _localFailure && widget.allowOnlineFallback
                  ? TextButton.icon(
                      onPressed: _switchOnline,
                      icon: const Icon(Icons.cloud_outlined),
                      label: const Text('改为在线播放'),
                    )
                  : !_localFailure &&
                          !widget.localOnly &&
                          widget.repository.supportsSourceManagement
                      ? SourceDiagnosticsButton(
                          repository: widget.repository,
                          store: widget.store,
                          drama: widget.detail.drama,
                        )
                      : null,
              icon: Icons.play_disabled_rounded,
            ),
          ),
        if ((_loading || _error != null) && _showFullscreen && !_television)
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Row(
                children: [
                  IconButton(
                    tooltip: '退出全屏',
                    onPressed: _rotate,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _openPanel(PlayerMenuSection.episodes),
                    child: const Text('选集'),
                  ),
                  IconButton(
                    tooltip: '播放设置',
                    onPressed: () => _openPanel(PlayerMenuSection.settings),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
            ),
          ),
        if (_saveWarning != null)
          Positioned(
            top: 52,
            left: 12,
            right: 12,
            child: SafeArea(
              bottom: false,
              child: Material(
                color: const Color(0xE6322424),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(_saveWarning!, style: const TextStyle(fontSize: 12)),
                      TextButton(
                        onPressed: _saveProgress,
                        child: const Text('重试保存'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _actionBar(Episode episode) => Container(
        color: const Color(0xFF191A20),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              IconButton(
                tooltip: '上一集',
                onPressed: _index > 0 ? () => _play(_index - 1) : null,
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              Flexible(
                child: TextButton(
                  onPressed: () => _openPanel(PlayerMenuSection.episodes),
                  child: Text(
                    '第 ${episode.number} 集 ▾',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              IconButton(
                tooltip: '下一集',
                onPressed: _index + 1 < widget.detail.episodes.length
                    ? () => _play(_index + 1)
                    : null,
                icon: const Icon(Icons.skip_next_rounded),
              ),
              const Spacer(),
              if (constraints.maxWidth >= 440)
                TextButton(
                  onPressed: () => _openPanel(PlayerMenuSection.speed),
                  child: Text('${_speed}x'),
                ),
              if (constraints.maxWidth >= 560)
                TextButton(
                  onPressed: () => _openPanel(PlayerMenuSection.quality),
                  child: Text(_qualityLabel),
                ),
              if (widget.mediaId == null)
                LanPushButton(
                  key: const ValueKey('player-lan-push'),
                  onPressed: _loading || _error != null ? null : _pushToDevice,
                ),
              IconButton(
                key: const ValueKey('player-danmaku-settings'),
                tooltip: '播放设置 · 画质、倍速与弹幕',
                onPressed: () => _openPanel(PlayerMenuSection.settings),
                icon: const Icon(Icons.tune_rounded),
              ),
            ],
          ),
        ),
      );

  Widget _episodePanel() => ColoredBox(
        color: const Color(0xFF101114),
        child: PlayerEpisodeGrid(
          episodes: widget.detail.episodes,
          currentIndex: _index,
          onSelected: (index) => _play(index),
        ),
      );
}
