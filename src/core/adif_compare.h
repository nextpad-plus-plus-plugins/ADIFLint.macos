// Comparing two logs QSO by QSO: what only one of them has, and what the same
// QSO says differently in each (a confirmation, a grid, a name). Compare and
// Merge Logs is built on it.
#pragma once

#include "adif_edit.h"
#include "adif_lint.h"
#include "adif_tools.h"

#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct FieldDiff {
    std::string field;        // upper case
    std::string here, there;  // "" where that log's record lacks the field
};

enum class CompareKind { OnlyThere, OnlyHere, Differ, Same };

struct CompareRow {
    CompareKind kind = CompareKind::Same;
    int here = -1, there = -1;     // DocModel groups (-1 for the log without it)
    std::vector<FieldDiff> diffs;  // Differ: each field whose values differ, or that one record lacks
};

// Pair the records of two logs as the same QSO (sameQso: CALL, band, mode, start
// within the window, no different station or park), the closest times first.
// Values are compared ignoring case and spaces around them, TIME_ON 1200 as
// 120000, and numbers (FREQ) by value. Rows: this log's records in order, each
// with its partner, then the other log's records nobody here matched.
std::vector<CompareRow> compareLogs(std::string_view here, const DocModel &hereModel, std::string_view there,
                                    const DocModel &thereModel, const DupeOptions &opt);

// What copying the other log's values into this one changes for a Differ row:
// the fields this record lacks, and with `replace` the ones it has differently
// too. Empty when there's nothing to copy.
std::vector<CellChange> copyChanges(const CompareRow &row, bool replace);

}  // namespace adif
