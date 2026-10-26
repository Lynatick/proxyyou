import 'dart:io';

import 'package:hiddify/core/db/database_uri.dart';
import 'package:path/path.dart' as p;

class ProfilePathResolver {
  const ProfilePathResolver(this._workingDir);

  final Directory _workingDir;

  Directory get directory => Directory(p.join(_workingDir.path, "configs"));

  File file(String fileName) {
    return File(p.join(directory.path, "$fileName.json"));
  }

  File tempFile(String fileName) => File(p.join(directory.path, '$fileName.download'));

  File get database => File(p.join(_workingDir.path, 'data', 'configurations.db'));

  String databaseLocation(String profileId, {String? operation}) => Uri(
    scheme: 'proxyyou-db',
    path: databaseUriPath(database.absolute.path),
    queryParameters: {'profile': profileId, if (operation != null) 'operation': operation},
  ).toString();
}
