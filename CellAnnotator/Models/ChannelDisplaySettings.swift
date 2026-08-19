//
//  ChannelDisplaySettings.swift
//  CellAnnotator
//

import Foundation
import SwiftUI
import UIKit

struct DisplayColor: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        let resolved = UIColor(color)
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        resolved.getRed(&red, green: &green, blue: &blue, alpha: nil)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

struct ChannelDisplaySettings: Identifiable, Equatable, Sendable {
    let channelIndex: Int
    let sourceChannelIndex: Int
    let sampleIndex: Int?
    var name: String
    var isVisible: Bool
    var color: DisplayColor
    var blackPoint: Double
    var whitePoint: Double
    var gamma: Double
    var opacity: Double

    var id: Int { channelIndex }

    static func defaults(for channels: [TIFFChannel]) -> [ChannelDisplaySettings] {
        let palette: [DisplayColor] = [
            DisplayColor(red: 1, green: 1, blue: 1),
            DisplayColor(red: 0.1, green: 1, blue: 0.2),
            DisplayColor(red: 1, green: 0.15, blue: 0.15),
            DisplayColor(red: 0.2, green: 0.45, blue: 1),
            DisplayColor(red: 1, green: 0.2, blue: 0.9),
            DisplayColor(red: 0.1, green: 1, blue: 1),
            DisplayColor(red: 1, green: 0.8, blue: 0.1)
        ]
        let containsInterleavedSamples = channels.contains { $0.sampleIndex != nil }
        return channels.map { channel in
            ChannelDisplaySettings(
                channelIndex: channel.index,
                sourceChannelIndex: channel.sourceChannelIndex,
                sampleIndex: channel.sampleIndex,
                name: channel.name,
                isVisible: containsInterleavedSamples ? channel.sampleIndex != nil : channel.index == 0,
                color: componentColor(channel.sampleIndex)
                    ?? color(fromOME: channel.color)
                    ?? palette[channel.index % palette.count],
                blackPoint: 0,
                whitePoint: 1,
                gamma: 1,
                opacity: 1
            )
        }
    }

    private static func componentColor(_ sampleIndex: Int?) -> DisplayColor? {
        switch sampleIndex {
        case 0: return DisplayColor(red: 1, green: 0, blue: 0)
        case 1: return DisplayColor(red: 0, green: 1, blue: 0)
        case 2: return DisplayColor(red: 0, green: 0, blue: 1)
        default: return nil
        }
    }

    private static func color(fromOME value: UInt32?) -> DisplayColor? {
        guard let value else { return nil }
        // OME Color is a signed 32-bit RGBA value in big-endian component order.
        let red = Double((value >> 24) & 0xff) / 255
        let green = Double((value >> 16) & 0xff) / 255
        let blue = Double((value >> 8) & 0xff) / 255
        guard red + green + blue > 0 else { return nil }
        return DisplayColor(red: red, green: green, blue: blue)
    }
}
