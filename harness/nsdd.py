"""Apple NSDataDetector (date detection), via pyobjc. macOS only.

NSDataDetector resolves dates against the Mac's real clock and has no public API for a reference
date, so we use it only to FIND date/time text in a message; resolver.py resolves that text
against each item's reference time.

    detect_dates("dinner Friday at 7?")  ->  [Match(text="dinner Friday at 7", start=0, end=18)]
"""
import sys
from dataclasses import dataclass
from functools import lru_cache


@dataclass(frozen=True)
class Match:
    text: str
    start: int
    end: int


def available():
    if sys.platform != "darwin":
        return False
    try:
        import Foundation  # noqa: F401
        return True
    except ImportError:
        return False


@lru_cache(maxsize=1)
def _detector():
    from Foundation import NSDataDetector, NSTextCheckingTypeDate
    det, err = NSDataDetector.dataDetectorWithTypes_error_(NSTextCheckingTypeDate, None)
    if det is None:
        raise RuntimeError(f"NSDataDetector unavailable: {err}")
    return det


def detect_dates(message):
    if not available():
        raise RuntimeError("NSDataDetector needs macOS with pyobjc-framework-Cocoa (see harness/requirements.txt)")
    from Foundation import NSString
    ns = NSString.stringWithString_(message)
    out = []
    for m in _detector().matchesInString_options_range_(ns, 0, (0, ns.length())):
        loc, length = m.range()
        text = str(ns.substringWithRange_(m.range()))
        # NSString ranges count UTF-16 units; map back to a Python string index.
        start = len(str(ns.substringToIndex_(loc)))
        out.append(Match(text, start, start + len(text)))
    return out
