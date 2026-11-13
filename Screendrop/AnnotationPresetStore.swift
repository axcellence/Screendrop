//
//  AnnotationPresetStore.swift
//  Screendrop
//
//  Created by Codex on 01/05/26.
//

import AppKit
import Foundation

enum AnnotationPresetStore {
    private static let key = "annotationStylePreset"

    static func load() -> AnnotationStylePreset {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preset = try? JSONDecoder().decode(AnnotationStylePreset.self, from: data) else {
            return AnnotationStylePreset()
        }

        return preset
    }

    static func save(_ preset: AnnotationStylePreset) {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

struct AnnotationStylePreset: Codable, Equatable {
    var selectedToolRawValue = AnnotationTool.rectangle.rawValue
    var swatchID = AnnotationSwatch.red.id
    var customSwatch: CodableSwatch?
    var strokeWidth: Double = 4
    var redactionDensity: Double = 0.55
    var textFontName = AnnotationTextMetrics.defaultFontName
    var textFontSize: Double = 48
    var textIsBold = true
    var textIsItalic = false
    var textIsUnderline = false
    var textAlignmentRawValue = NSTextAlignment.left.rawValue
    // Optional, so presets saved before these existed still load instead of resetting.
    var isHandDrawn: Bool?
    var markerSwatch: CodableSwatch?
    var markerWidth: Double?
    /// The font family, from the build that added Handwriting on. `textFontName` stays written as
    /// before, but presets saved earlier name SF Pro there, so they switch to Handwriting once.
    var textFontFamily: String?

    var selectedTool: AnnotationTool {
        AnnotationTool(rawValue: selectedToolRawValue) ?? .rectangle
    }

    var swatch: AnnotationSwatch {
        if let customSwatch {
            return customSwatch.annotationSwatch
        }

        return AnnotationSwatch.allCases.first { $0.id == swatchID } ?? .red
    }

    var textAlignment: NSTextAlignment {
        NSTextAlignment(rawValue: textAlignmentRawValue) ?? .left
    }

    /// Hand-drawn unless the user has switched to clean.
    var resolvedIsHandDrawn: Bool { isHandDrawn ?? true }

    var resolvedMarkerSwatch: AnnotationSwatch {
        guard let markerSwatch else { return .markerYellow }
        return AnnotationSwatch.allCases.first { $0.id == markerSwatch.id } ?? markerSwatch.annotationSwatch
    }

    var resolvedMarkerWidth: Double { markerWidth ?? 24 }

    /// Handwriting unless the user has picked another face since it was added.
    var resolvedTextFontFamily: AnnoFontFamily {
        textFontFamily.flatMap(AnnoFontFamily.init(rawValue:)) ?? .handwriting
    }
}

struct CodableSwatch: Codable, Equatable {
    var id: String
    var title: String
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(swatch: AnnotationSwatch) {
        id = swatch.id
        title = swatch.title
        red = Double(swatch.red)
        green = Double(swatch.green)
        blue = Double(swatch.blue)
        alpha = Double(swatch.alpha)
    }

    var annotationSwatch: AnnotationSwatch {
        AnnotationSwatch(
            id,
            title: title,
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}
