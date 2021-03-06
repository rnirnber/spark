// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library git.commands.clone;

import 'dart:async';
import 'dart:typed_data';

import 'package:chrome/chrome_app.dart' as chrome;

import '../config.dart';
import '../constants.dart';
import '../fast_sha.dart';
import '../file_operations.dart';
import '../http_fetcher.dart';
import '../objectstore.dart';
import '../object_utils.dart';
import '../options.dart';
import '../pack.dart';
import '../pack_index.dart';
import '../upload_pack_parser.dart';
import '../utils.dart';
import '../../utils.dart';

/**
 * This class implements the git clone command.
 */
class Clone {
  PrintProfiler _stopwatch;

  GitOptions _options;

  Clone(this._options) {
    if (_options.branchName == null) _options.branchName = 'master';
    if (_options.progressCallback == null) {
      _options.progressCallback = nopFunction;
    }
  }

  Future _writeRefs(chrome.DirectoryEntry dir, List<GitRef> refs) {
    return Future.forEach(refs, (GitRef ref) {
      String refName = ref.name.split('/').last;
      if (ref.name == "HEAD" || refName == "head" || refName == "merge")  {
        return new Future.value();
      }
      String path = REFS_REMOTE_HEADS + ref.name.split('/').last;
      return FileOps.createFileWithContent(dir, path, ref.sha, "Text");
    });
  }

  Future clone() {
    _stopwatch = new PrintProfiler('clone');
    return _clone(_options.repoUrl);
  }

  Future _clone(String url) {

    HttpFetcher fetcher = new HttpFetcher(_options.store, "origin", url,
        _options.username, _options.password);

    return fetcher.isValidRepoUrl(_options.repoUrl).then((isValid) {
      if (isValid) {
        return _startClone(fetcher);
      } else if (!url.endsWith('.git')) {
        return _clone(url + '.git');
      } else {
        return new Future.error('Invalid git repository url.');
      }
    });
  }

  Future _startClone(HttpFetcher  fetcher) {
    return _checkDirectory(_options.root, _options.store, nopFunction).then((_) {
      return  _options.root.createDirectory(".git").then(
          (chrome.DirectoryEntry gitDir) {
        return fetcher.fetchUploadRefs().then((List<GitRef> refs) {
          logger.info(_stopwatch.finishCurrentTask('fetchUploadRefs'));

          if (refs.isEmpty) {
            return _createInitialConfig(null, null);
          }

          GitRef remoteHeadRef, localHeadRef;
          String remoteHead;

          return _writeRefs(gitDir, refs).then((_) {
            refs.forEach((GitRef ref) {
              if (ref.name == "HEAD") {
                remoteHead = ref.sha;
              } else if (ref.name == REFS_HEADS + _options.branchName) {
                localHeadRef = ref;
              } else if (ref.name.indexOf(REFS_HEADS) == 0) {
                if (ref.sha == remoteHead) {
                  remoteHeadRef = ref;
                }
              }
            });

            if (localHeadRef == null) {
              if (_options.branchName == null) {
                //REMOTE_BRANCH_NOT_FOUND;
                return null;
              } else {
                localHeadRef = remoteHeadRef;
              }
            }

            logger.info(_stopwatch.finishCurrentTask('_writeRefs'));

            return _processClone(gitDir, localHeadRef, fetcher);
          });
        }, onError: (e) {
          // Clean-up git directory and then re-throw error.
          _options.root.getDirectory(".git").then(
              (chrome.DirectoryEntry gitDir) => gitDir.removeRecursively());
          throw "unable to load remote repo";
        }).whenComplete(() {
          logger.info(_stopwatch.finishProfiler());
        });
      });
    });
  }

  Future _createCurrentTreeFromPack(chrome.DirectoryEntry dir, ObjectStore store,
      String headSha) {
    return store.retrieveObject(headSha, ObjectTypes.COMMIT_STR).then((commit) {
          return ObjectUtils.expandTree(dir, store, commit.treeSha);
    });
  }

  // TODO error handling.
  Future _checkDirectory(chrome.DirectoryEntry dir, ObjectStore store, ferror) {

    return FileOps.listFiles(dir).then((entries) {
      if (entries.length == 0) {
        throw "CLONE_DIR_NOT_INTIALIZED";
      } else if (entries.length != 1 || entries.first.isFile
          || entries.first.name != '.git') {
        throw "CLONE_DIR_NOT_EMPTY";
      } else {
        return FileOps.listFiles(store.objectDir).then((entries) {
          if (entries.length > 1) {
            throw "CLONE_GIT_DIR_IN_USE";
          } else if (entries.length == 1) {
            if (entries.first.name == "pack") {
              return store.objectDir.getDirectory('pack').then(
                  (chrome.DirectoryEntry packDir) {
                return FileOps.listFiles(packDir).then((entries) {
                  if (entries.length > 0) {
                    throw "CLONE_GIT_DIR_IN_USE";
                  } else {
                    return null;
                  }
                }, onError: (e) {
                  ferror();
                  throw e;
                });
              }, onError: (e) {
                ferror();
                throw e;
              });
            }
          }
        }, onError: (e) {
          ferror();
          throw e;
        });
      }
    }, onError: (e) {
      ferror();
      throw e;
    });
  }

  Future<chrome.Entry> _createInitialConfig(String shallow,
      GitRef localHeadRef) {
    Config config = _options.store.config;
    config.url = _options.repoUrl;
    config.time = new DateTime.now();

    if (_options.depth != null && shallow != null) {
      config.shallow = shallow;
    }

    if (localHeadRef != null) {
      config.remoteHeads[localHeadRef.name]= localHeadRef.sha;
    }
    return _options.store.writeConfig();
  }

  Future _createPackFiles(chrome.DirectoryEntry objectsDir, String packName,
      Uint8List packData, Uint8List packIdxData) {
    return FileOps.createFileWithContent(objectsDir, 'pack/${packName}.pack',
        packData, "blob").then((_) {
          return FileOps.createFileWithContent(objectsDir,
              'pack/${packName}.idx', packIdxData, "blob");
        });
  }

  Future _processClone(chrome.DirectoryEntry gitDir, GitRef localHeadRef,
      HttpFetcher fetcher) {
    return FileOps.createFileWithContent(gitDir, "HEAD",
        "ref: ${localHeadRef.name}\n", "Text").then((_) {
      return FileOps.createFileWithContent(gitDir, localHeadRef.name,
          localHeadRef.sha, "Text").then((_) {
        return fetcher.fetchRef([localHeadRef.sha], null, null, _options.depth,
            null, nopFunction, nopFunction).then((PackParseResult result) {
          Uint8List packData = result.data;
          List<int> packSha = packData.sublist(packData.length - 20);
          Uint8List packIdxData = PackIndex.writePackIndex(result.objects,
              packSha);
          // get a view of the sorted shas.
          int offset = 4 + 4 + (256 * 4);
          Uint8List sortedShas = packIdxData.sublist(offset,
              offset + result.objects.length * 20);
          FastSha sha1 = new FastSha();
          sha1.add(sortedShas);
          String packNameSha = shaBytesToString(sha1.close());

          String packName = 'pack-${packNameSha}';

          logger.info(_stopwatch.finishCurrentTask('create HEAD'));

          return gitDir.createDirectory('objects').then(
              (chrome.DirectoryEntry objectsDir) {
            return _createPackFiles(objectsDir, packName, packData,
                packIdxData).then((_) {
              logger.info(_stopwatch.finishCurrentTask('createPackFiles'));
              PackIndex packIdx = new PackIndex(packIdxData.buffer);
              Pack pack = new Pack(packData, _options.store);
              _options.store.loadWith(objectsDir, [new PackEntry(pack, packIdx)]);
              //TODO add progress
              //progress({pct: 95, msg: "Building file tree from pack. Be patient..."});
              return _createCurrentTreeFromPack(_options.root, _options.store,
                  localHeadRef.sha).then((_) {
                logger.info(_stopwatch.finishCurrentTask('createCurrentTreeFromPack'));
                return _createInitialConfig(result.shallow, localHeadRef)
                    .then((_) {
                  logger.info(_stopwatch.finishCurrentTask('createInitialConfig'));
                  _options.store.index.reset(true);
                });
              });
            });
          });
        });
      });
    });
  }
}
