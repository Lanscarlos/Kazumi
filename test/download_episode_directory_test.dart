import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/file_system.dart';
import 'package:path/path.dart' as path;

void main() {
  test('episode directory is <base>/<bangumiId>_<pluginName>/<episode>', () {
    final base = path.join('root', 'downloads');
    expect(
      downloadEpisodeDirectory(base, 123, 'source', 4),
      path.join(base, '123_source', '4'),
    );
  });
}
