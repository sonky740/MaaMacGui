# Korean catalog regression check

Run from any directory with Python 3 and Git. The baseline is mandatory: use the immutable full commit hash from **before** the Korean catalog work, not HEAD (which changes after committing). For this work the baseline is `100c6d8bc2c13c1efe83cf8075a73f7cb3c42140`.

```sh
python3 scripts/check_korean_catalog.py --baseline-commit 100c6d8bc2c13c1efe83cf8075a73f7cb3c42140 --negative-tests
python3 -O scripts/check_korean_catalog.py --baseline-commit 100c6d8bc2c13c1efe83cf8075a73f7cb3c42140 --negative-tests
```

Alternatively supply `--baseline-file PATH` for the original catalog and `--catalog PATH` to validate a different target. Without `--catalog`, the repository catalog is used. The check rejects duplicate JSON keys; changes to original structure, other languages, and existing Korean except the five exact reviewed replacements; and placeholder or newline mismatches in changed Korean. Negative fixtures intentionally corrupt the target and must be rejected; they are only in memory. The fixture keys are specific to this catalog. A nonzero exit denotes failure. The comparison is semantic JSON, not whitespace or key ordering.
