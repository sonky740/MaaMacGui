# Korean catalog regression check

Run from any directory with Python 3 and Git. The baseline is mandatory: use the immutable full commit hash from **before** the Korean catalog work, not HEAD (which changes after committing). For this work the baseline is `100c6d8bc2c13c1efe83cf8075a73f7cb3c42140`.

```sh
python3 scripts/check_korean_catalog.py --baseline-commit 100c6d8bc2c13c1efe83cf8075a73f7cb3c42140 --negative-tests
python3 -O scripts/check_korean_catalog.py --baseline-commit 100c6d8bc2c13c1efe83cf8075a73f7cb3c42140 --negative-tests
```

Alternatively supply `--baseline-file PATH` for the original catalog and `--catalog PATH` to validate a different target. Without `--catalog`, the repository catalog is used. The check rejects duplicate JSON keys; changes to original structure, other languages, and existing Korean except the five exact reviewed replacements; and placeholder or newline mismatches in changed Korean. Negative fixtures intentionally corrupt the target and must be rejected; they are only in memory. The fixture keys are specific to this catalog. A nonzero exit denotes failure. The comparison is semantic JSON, not whitespace or key ordering.

Both commands also check the repository's `RoguelikeOptions.xcstrings` against the non-Sarkaz squad and recruitment IDs in the Swift settings, the BlackFlow strategy profiles, and the integer difficulty format.

## Korean input regressions

From the Mac GUI repository, run the Swift checks against a packaged resource directory. Temporary fixtures add and replace names in the same process. The checks do not connect to a device.

```zsh
resources="$HOME/Applications/MAA.app/Contents/Resources/resource"
checks=$(mktemp -d)
swiftc MeoAsstMac/Model/{InputDraft,KoreanInputResources,KoreanOperatorNames}.swift scripts/check_korean_operators.swift -o "$checks/operators"
swiftc MeoAsstMac/Model/{KoreanInputResources,KoreanOCRTasks,KoreanSamiNames}.swift scripts/check_korean_sami.swift -o "$checks/sami"
swiftc MeoAsstMac/Model/{KoreanInputResources,KoreanOCRTasks,KoreanShopNames}.swift scripts/check_korean_shop.swift -o "$checks/shop"
swiftc MeoAsstMac/Model/FightDropItems.swift scripts/check_korean_drop_items.swift -o "$checks/drops"
for check in "$checks"/{operators,sami,shop,drops}; do "$check" "$resources" || break; done
```
