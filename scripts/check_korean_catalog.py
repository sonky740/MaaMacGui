#!/usr/bin/env python3
import collections, copy, json, re, subprocess, sys
import argparse

class ValidationError(Exception):
    pass
from pathlib import Path
REVIEWED = {'GameDrop': {'stringUnit': {'state': 'translated', 'value': '게임 연결이 끊겨 작업을 중지합니다'}}, 'TotalDrop': {'stringUnit': {'state': 'translated', 'value': '%1$(code)@ 드롭 통계:\n%2$(drops)@%3$(extras)@'}}, 'InfrastDormDoubleConfirmed': {'stringUnit': {'state': 'translated', 'value': '오퍼레이터가 다른 시설에 배치되어 있어 이동을 자동으로 확인했습니다'}}, 'UnsupportedLevel': {'stringUnit': {'state': 'translated', 'value': '지원되지 않는 스테이지 “%1$(level)@”입니다. 스테이지 이름을 확인하거나 왼쪽 아래에서 리소스 업데이트를 시도해 주세요!'}}, 'ResolutionNotSupported': {'stringUnit': {'state': 'translated', 'value': '지원되지 않는 에뮬레이터 해상도입니다. 720p 이상, 16:9 비율로 설정해 주세요. 1280×720 또는 1920×1080을 권장합니다.'}}}

def unique_object(pairs):
    result = {}
    for (k, v) in pairs:
        if k in result:
            raise ValueError(f'Duplicate JSON key: {k!r}')
        result[k] = v
    return result

def load(text):
    return json.loads(text, object_pairs_hook=unique_object)

def tokens(s):
    return collections.Counter(re.findall('%(?:%|(?:\\d+\\$)?(?:\\([^)]+\\))?[-+#0 ]*(?:\\d+|\\*)?(?:\\.(?:\\d+|\\*))?(?:hh|ll|h|l|q|z|t|j|L)?[@diuoxXfFeEgGaAcCsSp])', s))

def check(before, after):
    if not before.keys() == after.keys():
        raise ValidationError('Root structure changed')
    if not before['sourceLanguage'] == after['sourceLanguage']:
        raise ValidationError('Validation failed')
    if not before['strings'].keys() == after['strings'].keys():
        raise ValidationError('Source keys changed')
    stripped = copy.deepcopy(after)
    added = []
    for (key, entry) in after['strings'].items():
        old = before['strings'][key]
        newko = entry.get('localizations', {}).get('ko')
        oldko = old.get('localizations', {}).get('ko')
        if key in REVIEWED and (oldko is None or oldko.get('stringUnit', {}).get('state') != 'needs_review' or newko != REVIEWED[key]):
            raise ValidationError(f'Missing or invalid reviewed replacement: {key!r}')
        if newko != oldko:
            if oldko is not None:
                if not (key in REVIEWED and newko == REVIEWED[key]):
                    raise ValidationError(f'Existing Korean altered: {key!r}')
                if not oldko.get('stringUnit', {}).get('state') == 'needs_review':
                    raise ValidationError(f'Unexpected original state: {key!r}')
                source = old.get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value', key)
                value = newko['stringUnit']['value']
                if not tokens(source) == tokens(value):
                    raise ValidationError(f'Reviewed placeholder mismatch: {key!r}')
                if not source.count('\n') == value.count('\n'):
                    raise ValidationError(f'Reviewed newline mismatch: {key!r}')
                stripped['strings'][key]['localizations']['ko'] = copy.deepcopy(oldko)
                continue
            if not newko is not None:
                raise ValidationError(f'Korean removed: {key!r}')
            if not old.get('shouldTranslate') is not False:
                raise ValidationError(f'Non-translatable key: {key!r}')
            if not (set(newko) == {'stringUnit'} and newko['stringUnit'].get('state') == 'translated'):
                raise ValidationError(f'Unexpected Korean structure: {key!r}')
            value = newko['stringUnit']['value']
            source = old.get('localizations', {}).get('zh-Hans', {}).get('stringUnit', {}).get('value', key)
            if not tokens(source) == tokens(value):
                raise ValidationError(f'Placeholder mismatch: {key!r}: {tokens(source)} != {tokens(value)}')
            if source.count('\n') != value.count('\n'):
                raise ValidationError(f'Newline mismatch: {key!r}')
            del stripped['strings'][key]['localizations']['ko']
            if 'localizations' not in old and (not stripped['strings'][key]['localizations']):
                del stripped['strings'][key]['localizations']
            added.append(key)
    if not stripped == before:
        raise ValidationError('Original entries, other languages, metadata, or plural structure changed')
    return added

def negative_tests(before, after):
    def rejected(name, candidate):
        try:
            check(before, candidate)
        except ValidationError:
            print(f"Negative test passed: {name}")
        else:
            raise ValidationError(f"Negative fixture not rejected: {name}")
    for name, key, lang, value in [
        ("placeholder", "已连接至 %@", "ko", "연결됨"),
        ("existing Korean", "CurrentStage", "ko", "변조"),
        ("reviewed Korean", "GameDrop", "ko", "변조"),
        ("other language", "GameDrop", "zh-Hans", "변조"),
        ("newline", "TotalDrop", "ko", "%1$(code)@ 드롭 통계: %2$(drops)@%3$(extras)@"),
    ]:
        candidate = copy.deepcopy(after)
        candidate["strings"][key]["localizations"][lang]["stringUnit"]["value"] = value
        rejected(name, candidate)
    candidate = copy.deepcopy(after)
    candidate["sourceLanguage"] = "en"
    rejected("root structure", candidate)
    try:
        load('{"duplicate": 1, "duplicate": 2}')
    except ValueError:
        print("Negative test passed: duplicate JSON key")
    else:
        raise ValidationError("Duplicate JSON fixture not rejected")


def main():
    parser = argparse.ArgumentParser(description="Check Korean catalog against an explicit baseline.")
    baseline = parser.add_mutually_exclusive_group(required=True)
    baseline.add_argument("--baseline-commit", help="Git commit containing the original catalog (use a full hash)")
    baseline.add_argument("--baseline-file", type=Path, help="Original catalog JSON file")
    parser.add_argument("--catalog", type=Path, default=Path(__file__).resolve().parents[1] / "Resources/Localizable.xcstrings", help="Catalog to validate")
    parser.add_argument("--negative-tests", action="store_true", help="Run regression fixtures against this catalog")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.baseline_commit:
        # Resolve to a commit first; do not silently use the changing HEAD.
        commit = subprocess.check_output(["git", "rev-parse", "--verify", args.baseline_commit + "^{commit}"], cwd=root, text=True).strip()
        original = subprocess.check_output(["git", "show", commit + ":Resources/Localizable.xcstrings"], cwd=root, text=True)
    else:
        original = args.baseline_file.read_text(encoding="utf-8")
    before = load(original)
    after = load(args.catalog.read_text(encoding="utf-8"))
    added = check(before, after)
    if args.negative_tests:
        negative_tests(before, after)
    print(f"Catalog valid; {len(added)} Korean translations added; {len(REVIEWED)} reviewed replacements verified")


if __name__ == "__main__":
    try:
        main()
    except (ValidationError, ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"Validation failed: {exc}", file=sys.stderr)
        sys.exit(1)
