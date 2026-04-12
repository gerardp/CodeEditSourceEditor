//
//  GutterChangeData.swift
//  CodeEditSourceEditor
//
//  Created by Abe Malla on 4/10/26.
//

import AppKit

/// Represents a single contiguous change region in the gutter.
///
/// This is the data type that the source editor package uses to render git change indicators.
/// The source editor package is git-agnostic - the host app provides these values.
public struct GutterChange: Equatable, Sendable {
    /// The type of change for a gutter indicator.
    public enum ChangeType: Sendable {
        /// Lines were added.
        case added
        /// Lines were modified.
        case modified
        /// Lines were deleted at this position.
        case deleted
    }

    /// The type of change.
    public let type: ChangeType

    /// The range of 0-indexed line numbers in the modified (current) document that this change covers.
    ///
    /// For `deleted` changes, this is a single-element range indicating the line *after* which the deletion occurred.
    public let lineRange: Range<Int>

    public init(type: ChangeType, lineRange: Range<Int>) {
        self.type = type
        self.lineRange = lineRange
    }
}
