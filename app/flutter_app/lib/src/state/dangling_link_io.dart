/// 데스크톱 저장소(`config_store_io.dart`, `window_connections_store_io.dart`)가
/// 같이 쓰는 "파일 없음" 판정 보조.
///
/// 읽기가 `PathNotFoundException`(ENOENT)으로 끝나도 저장된 것이 없다는
/// 뜻이 아닐 수 있다. 파일 자신이나 상위 디렉터리(예:
/// `~/.local/state/my-dashboard`)가 대상이 없는 링크면 마운트되지 않은
/// 볼륨이나 옮겨 간 디렉터리를 가리키고 있을 수 있다. 그때 빈 값으로 접으면
/// 첫 실행으로 뜨고, 다음 저장이 링크를 일반 파일로 바꾸거나(파일 자신일
/// 때) 실패한다(상위 디렉터리일 때).
library;

import 'dart:io';

/// [path]를 읽다 ENOENT가 났을 때 그 원인인 대상 없는 링크의 경로를 돌려준다.
/// 없으면 null이다.
///
/// 파일 자신부터 위로 올라가며, 링크를 따라가지 않고 처음으로 존재하는
/// 항목을 찾는다. 그 항목이 대상을 찾을 수 없는 링크면 그 경로가 답이다.
/// 링크가 아니거나 대상이 있으면 null이다 — 그 항목까지는 경로가 풀렸으므로
/// 그 위는 볼 필요가 없고, 그 아래가 정말로 없다는 뜻이다.
Future<String?> danglingLinkOnPath(String path) async {
  var current = File(path).absolute.path;
  while (true) {
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.link) return null;
      final target = await FileSystemEntity.type(current);
      return target == FileSystemEntityType.notFound ? current : null;
    }
    final parent = File(current).parent.path;
    if (parent == current) return null;
    current = parent;
  }
}
