/// Values shared by the package tests.
library;

/// The read time every listing fixture carries. One date, so a test that
/// compares listings across files never fails on a timestamp nobody chose.
final DateTime testReadAt = DateTime(2026, 10, 6);
