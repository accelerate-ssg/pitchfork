import times, os, strutils, sets, sequtils, tables
import helpers

resetOutputFormatters()
addOutputFormatter(formatter)

# Load test groups from JSON file
let jsonPath = currentSourcePath().parentDir() / "golden_liquid.json"
let jsonContent = readFile(jsonPath)
let testData = parseJson(jsonContent)

# Every group in golden_liquid.json runs unless it is named here. Skipping is
# opt-out, never opt-in: a group we forget about must fail loudly rather than
# silently vanish from the totals. Entries are the normalized suite name, i.e.
# the group name with the "liquid.golden." prefix dropped and underscores
# turned into spaces.
let skippedSuites = initHashSet[string]()

var seenSuites = initHashSet[string]()
var skippedCases = 0

let t0 = cpuTime()

# Run tests from JSON
for testGroup in testData["test_groups"]:
  let groupName = testGroup["name"].getStr()
  # Extract suite name from group name (e.g., "liquid.golden.assign_tag" -> "assign tag")
  if not groupName.startsWith("liquid.golden."):
    echo "Unclassifiable test group name: " & groupName
    quit(1)
  let suiteName = groupName.replace("liquid.golden.", "").replace("_", " ")
  seenSuites.incl(suiteName)

  # Skip disabled test groups
  if suiteName in skippedSuites:
    skippedCases += testGroup["tests"].len
    continue

  suite suiteName:
    for test in testGroup["tests"]:
      let name = test["name"].getStr()
      let source = test["template"].getStr()
      let want = test["want"].getStr()
      let context = test["context"]
      let partials = if test.hasKey("partials"):
        var p = initTable[string, string]()
        for key, val in test["partials"]:
          p[key] = val.getStr()
        p
      else:
        initTable[string, string]()
      let error = test["error"].getBool()
      let strict = test["strict"].getBool()
      
      testCase(name, source, context, want, partials, error, strict)

# A skip entry that matches no group is a stale entry hiding a rename; fail
# rather than quietly protecting nothing.
let staleSkips = skippedSuites - seenSuites
if staleSkips.len > 0:
  echo "Skip list names groups that are not in golden_liquid.json: " &
    toSeq(staleSkips.items).join(", ")
  quit(1)

let t1 = cpuTime()
let duration = t1 - t0

let failures = getFailures()
let failuresCount = failures.len
let successesCount = getSuccesses()
let totalCount = failuresCount + successesCount;

# Print failure summary
if failuresCount > 0:
  echo "\nFailures:"
  var suiteName = ""
  for failure in failures:
    if failure.suiteName != suiteName:
      suiteName = failure.suiteName
      echo "\n  " & suiteName
    echo "    " & failure.testName
  echo ""
  echo "Duration: " & $duration & " seconds"
  echo "Total tests: " & $totalCount & ", Successes: " & $successesCount & ", Failures: " & $failuresCount
  if skippedCases > 0:
    echo "Skipped " & $skippedCases & " cases in: " &
      toSeq(skippedSuites.items).join(", ")
  quit(1)
else:
  echo "Duration: " & $duration & " seconds"
  echo "All " & $totalCount & " tests passed!"
  if skippedCases > 0:
    echo "Skipped " & $skippedCases & " cases in: " &
      toSeq(skippedSuites.items).join(", ")
  quit(0)
