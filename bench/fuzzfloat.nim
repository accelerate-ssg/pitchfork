## Fuzz float_to_string's fast path: does what we print always read back
## as the same double, and how does it compare with Nim's own rendering?
import std/[random, strutils, math]
import ../src/pitchfork/values

proc old_impl(f: float64): string =
  result = $f
  if result.len >= 17 and result.parseFloat() != f:
    result = f.formatFloat(ffDefault, 17)
  let e = result.find('e')
  if e > 0 and result.find('.', 0, e - 1) < 0:
    result.insert(".0", e)

var checked, broke_new, broke_old, differed, shorter, longer = 0
var shown = 0

proc check(f: float64) =
  if f != f or abs(f) == Inf: return
  inc checked
  let got = float_to_string(f)
  let want = old_impl(f)
  let got_rt = got.parseFloat() == f
  let want_rt = want.parseFloat() == f
  if not got_rt: inc broke_new
  if not want_rt: inc broke_old
  if got != want:
    inc differed
    if got.len < want.len: inc shorter else: inc longer
  if not got_rt and shown < 12:
    inc shown
    echo "NEW FAILS ROUND TRIP  bits=0x", toHex(cast[uint64](f)),
         "  got=", got, "  old=", want, "  old_rt=", want_rt

for v in [0.0, -0.0, 1.0, 0.1, 0.5, 2.2, 10.1, 7.9, 4.6, 15.15, 100.0,
          1e15, 1e16, 1e-4, 1e-5, 1e22, 1e300, 0.001, 2.857142857142857,
          1.4428571428571428, 9007199254740992.0, 4.9e-324]:
  check(v); check(-v)
for i in -200_000 .. 200_000:
  check(i.float / 10.0); check(i.float / 100.0); check(i.float / 1000.0)
for i in 1 .. 100_000:
  for d in [3.0, 7.0, 9.0, 11.0]: check(i.float / d)
var rng = initRand(20260825)
for _ in 0 ..< 3_000_000: check(cast[float64](rng.next()))
for _ in 0 ..< 2_000_000:
  check(rng.rand(-1e15 .. 1e15)); check(rng.rand(-1.0 .. 1.0))

echo "checked           ", checked
echo "new never reads back: ", broke_new, "   old never reads back: ", broke_old
echo "differed from old:    ", differed, "  (shorter ", shorter, " / longer ", longer, ")"
if broke_new > 0: quit(1)
