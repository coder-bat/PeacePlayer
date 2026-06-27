//
//  Snapshotable.swift
//  PeacePlayer
//
//  Property-wrapper marker for snapshot-eligible state, as expected by
//  the ios-qa StateServer. The wrapper is a no-op at runtime — the
//  codegen tool detects the @Snapshotable attribute via AST inspection
//  and emits register/read/write blocks per marked field.
//
//  Pattern matches the gstack fixture (ios-qa skill) so the same
//  codegen pipeline works without modification.
//
//  This file is intentionally #if DEBUG-gated: Snapshotable is only
//  meaningful when the StateServer is running, and the StateServer only
//  runs in debug builds. In release builds the @Snapshotable attribute
//  wouldn't be visible to the codegen tool anyway (it doesn't run in
//  release), so removing it at compile time is safe and slightly trims
//  the binary.
//

#if DEBUG

import Foundation

/// Property wrapper marker for snapshot-eligible state. The actual
/// wrapper is a no-op at runtime; codegen-tool detection happens via
/// attribute scan on the AST.
@propertyWrapper
public struct Snapshotable<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

#endif // DEBUG
