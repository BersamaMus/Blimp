import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/music_controller.dart';
import '../theme.dart';

/// A mute button and a volume slider. The mouse wheel over either turns it up
/// or down.
class VolumeControl extends StatefulWidget {
  const VolumeControl({super.key, required this.music, this.sliderWidth = 110});

  final MusicController music;
  final double sliderWidth;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  /// What unmuting goes back to.
  double _beforeMute = 1;

  void _onScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
    // Claimed, so whatever scrolls behind doesn't scroll too.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final music = widget.music;
      music.setVolume(music.volume.value - event.scrollDelta.dy.sign * 0.05);
    });
  }

  @override
  Widget build(BuildContext context) {
    final music = widget.music;
    return Listener(
      onPointerSignal: _onScroll,
      child: ValueListenableBuilder(
        valueListenable: music.volume,
        builder: (context, volume, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: volume == 0 ? 'Unmute' : 'Mute',
              color: AppColors.textSecondary,
              icon: Icon(
                volume == 0
                    ? Icons.volume_off_rounded
                    : volume < 0.5
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded,
              ),
              onPressed: () {
                if (volume == 0) {
                  music.setVolume(_beforeMute);
                } else {
                  _beforeMute = volume;
                  music.setVolume(0);
                }
              },
            ),
            SizedBox(
              width: widget.sliderWidth,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  value: volume,
                  semanticFormatterCallback: (v) => 'Volume ${(v * 100).round()}%',
                  onChanged: (v) => music.setVolume(v, save: false),
                  onChangeEnd: music.setVolume,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
