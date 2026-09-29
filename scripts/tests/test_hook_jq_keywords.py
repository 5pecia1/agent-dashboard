"""Static jq 1.6 portability gate: hook scripts must not use jq 1.6 keywords as jq variable names."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

# jq 1.6 렉서의 키워드. jq 1.7부터는 변수 이름으로 써도 되지만 jq 1.6(Debian 12·devcontainer)에서는
# 컴파일 에러다. privacy 필터가 `$include`를 쓰던 때 jq 1.6 기계에서는 필터가 빈 결과를 내서 모든
# 전송과 스풀 기록이 조용히 사라졌고, macOS(jq 1.7.1)에서 도는 테스트는 이를 잡지 못했다.
# 그래서 jq 1.6 없이도 도는 정적 검사로 막는다.
# `$__loc__`는 jq 1.6에도 있는 특수 변수라 참조는 허용하고 이름으로 묶는 것만 막는다.
JQ16_KEYWORDS = ('if', 'then', 'elif', 'else', 'end', 'as', 'def', 'reduce', 'foreach', 'try', 'catch',
                 'label', 'break', 'import', 'include', 'module', 'and', 'or', 'not', '__loc__')
_ANY_KEYWORD = '|'.join(re.escape(keyword) for keyword in JQ16_KEYWORDS)
_REFERENCE_KEYWORD = '|'.join(re.escape(keyword) for keyword in JQ16_KEYWORDS if keyword != '__loc__')
_WHOLE = r'(?![A-Za-z0-9_])'  # $include_content·$raw_event 같은 긴 이름은 키워드가 아니다.
JQ16_KEYWORD_VARIABLE = re.compile(
    rf'--(?:arg|argjson|slurpfile|rawfile)\s+(?:{_ANY_KEYWORD}){_WHOLE}'
    rf'|\bas\s+\$(?:{_ANY_KEYWORD}){_WHOLE}'
    rf'|\$(?:{_REFERENCE_KEYWORD}){_WHOLE}')


def jq16_keyword_variables(text):
    """jq 변수 이름으로 쓰인 jq 1.6 키워드를 [(줄 번호, 일치 문자열)]로 돌려준다."""
    return [(number, match.group(0)) for number, line in enumerate(text.splitlines(), 1)
            for match in JQ16_KEYWORD_VARIABLE.finditer(line)]


class JqKeywordVariableTests(unittest.TestCase):
    def test_검사기는_키워드_변수만_이름_전체로_찾는다(self):
        for text in ('--arg include "$X"', "'if $include == \"1\" then . else . end'", '--argjson end 1',
                     "'.a as $then | $then'", '--slurpfile def f.json', '--arg __loc__ x', "'. as $__loc__ | .'"):
            with self.subTest(text=text):
                self.assertTrue(jq16_keyword_variables(text))
        for text in ('--arg include_content "$X"', "'if $include_content == \"1\"'", "'$raw_event'",
                     "'$ends'", '"${end}"', "'{file: $__loc__.file}'", '--arg project "$P"', 'alias $x'):
            with self.subTest(text=text):
                self.assertEqual(jq16_keyword_variables(text), [])

    def test_hook_스크립트는_jq16_키워드를_변수_이름으로_쓰지_않는다(self):
        problems = [f'{path.relative_to(ROOT)}:{number}: {found}'
                    for path in sorted((ROOT / 'hooks').glob('*.sh'))
                    for number, found in jq16_keyword_variables(path.read_text(encoding='utf-8'))]
        self.assertEqual(problems, [], (
            'jq 1.6 키워드를 jq 변수 이름으로 쓰면 jq 1.6(Debian 12·devcontainer)에서 필터 전체가 컴파일 '
            '에러가 나고 hook이 조용히 아무것도 보내지 않는다. 이름을 바꿔라(예: $include -> '
            '$include_content). bash 변수라도 이 검사는 구분하지 못하므로 이름을 바꾸거나 ${name}으로 써라:\n  '
            + '\n  '.join(problems)))


if __name__ == '__main__':
    unittest.main()
