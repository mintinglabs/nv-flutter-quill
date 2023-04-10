import 'dart:io';

import 'package:cached_video_player/cached_video_player.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../flutter_quill.dart';

/// Widget for playing back video
/// Refer to https://github.com/flutter/plugins/tree/master/packages/video_player/video_player
class VideoApp extends StatefulWidget {
  const VideoApp({
    required this.videoUrl,
    required this.context,
    required this.readOnly,
  });

  final String videoUrl;
  final BuildContext context;
  final bool readOnly;

  @override
  _VideoAppState createState() => _VideoAppState();
}

class _VideoAppState extends State<VideoApp> {
  late final CachedVideoPlayerController _controller;
  final GlobalKey videoContainerKey = GlobalKey();

  @override
  void initState() {
    super.initState();

    _controller = widget.videoUrl.startsWith('http')
        ? CachedVideoPlayerController.network(widget.videoUrl)
        : CachedVideoPlayerController.file(File(widget.videoUrl))
      ..initialize().then((_) {
        // Ensure the first frame is shown after the video is initialized,
        // even before the play button has been pressed.
        setState(() {});
      }).catchError((error) {
        setState(() {});
      });
  }

  @override
  Widget build(BuildContext context) {
    final defaultStyles = DefaultStyles.getInstance(context);
    if (_controller.value.hasError) {
      if (widget.readOnly) {
        return RichText(
          text: TextSpan(
              text: widget.videoUrl,
              style: defaultStyles.link,
              recognizer: TapGestureRecognizer()
                ..onTap = () => launchUrl(Uri.parse(widget.videoUrl))),
        );
      }

      return RichText(
          text: TextSpan(text: widget.videoUrl, style: defaultStyles.link));
    } else if (!_controller.value.isInitialized) {
      return VideoProgressIndicator(
        _controller,
        allowScrubbing: true,
        colors: const VideoProgressColors(playedColor: Colors.blue),
      );
    }

    return Container(
      key: videoContainerKey,
      // height: 300,
      child: InkWell(
        onTap: () {
          setState(() {
            _controller.value.isPlaying
                ? _controller.pause()
                : _controller.play();
          });
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: CachedVideoPlayer(_controller),
              ),
            ),
            _controller.value.isPlaying
                ? const SizedBox.shrink()
                : const ColoredBox(
                    color: Color(0xfff5f5f5),
                    child: Icon(
                      Icons.play_arrow,
                      size: 60,
                      color: Colors.blueGrey,
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    _controller.dispose();
  }
}