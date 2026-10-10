import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/download/download_page.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/lan_share_page.dart';
import 'package:kazumi/repositories/download_repository.dart';

final downloadModule = createModule(
  path: '/download',
  register: (c) {
    c
      ..route(
        '/',
        child: (context, state) => DownloadPage(
          controller: inject<DownloadController>(),
        ),
      )
      ..route(
        '/lan-share',
        child: (context, state) => LanSharePage(
          repository: inject<IDownloadRepository>(),
        ),
      );
  },
);
