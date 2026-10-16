import QtQuick

// The first Qt pane's section, kept as an adapter onto MacSection so a pane
// written against `Section { title: ... }` still folds and draws like the
// rest of the rail. New code uses MacSection with its own sectionId.
MacSection {
    sectionId: "legacy." + title
}
