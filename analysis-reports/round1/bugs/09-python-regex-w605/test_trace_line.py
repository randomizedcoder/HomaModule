# Bug 9 — table-driven pytest. Run: python -W error::DeprecationWarning -m pytest
import re

import pytest

PATTERN = re.compile(r' *([-0-9.]+) us .* \[C([0-9]+)\]')


@pytest.mark.parametrize("name,line,expected", [
    ("well-formed",  "  12.5 us foo [C3]", ("12.5", "3")),
    ("missing-brkt", "  12.5 us foo C3",   None),
    ("zero-core",    "  0.0 us x [C0]",    ("0.0", "0")),
    ("non-numeric",  "  1.0 us x [CZ]",    None),
])
def test_trace_line(name, line, expected):
    m = PATTERN.match(line)
    assert (m.groups() if m else None) == expected
