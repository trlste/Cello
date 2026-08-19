//
//  OMEXMLParser.swift
//  CellAnnotator
//

import Foundation

struct OMETiffData: Equatable, Sendable {
    let ifd: Int
    let firstC: Int
    let firstZ: Int
    let firstT: Int
    let planeCount: Int?
}

struct OMEMetadata: Equatable, Sendable {
    let sizeX: Int
    let sizeY: Int
    let sizeZ: Int
    let sizeC: Int
    let sizeT: Int
    let dimensionOrder: String
    let pixelType: String?
    let significantBits: Int?
    let physicalSizeX: Double?
    let physicalSizeY: Double?
    let physicalSizeXUnit: String?
    let physicalSizeYUnit: String?
    let channels: [TIFFChannel]
    let tiffData: [OMETiffData]
}

enum OMEXMLParser {
    enum ParseError: LocalizedError {
        case invalidXML
        case missingPixels

        var errorDescription: String? {
            switch self {
            case .invalidXML: return "The OME-XML metadata is malformed."
            case .missingPixels: return "The OME-XML does not contain a Pixels element."
            }
        }
    }

    static func parse(_ xml: String) throws -> OMEMetadata {
        guard let data = xml.data(using: .utf8) else { throw ParseError.invalidXML }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { throw parser.parserError ?? ParseError.invalidXML }
        guard let pixels = delegate.pixels else { throw ParseError.missingPixels }

        let channels: [TIFFChannel]
        if delegate.channels.isEmpty {
            channels = (0..<pixels.sizeC).map {
                TIFFChannel(
                    index: $0,
                    idString: nil,
                    name: "Channel \($0 + 1)",
                    color: nil,
                    sourceChannelIndex: $0,
                    sampleIndex: nil,
                    samplesPerPixel: 1
                )
            }
        } else {
            var expanded: [TIFFChannel] = []
            var sourceC = 0
            for channel in delegate.channels where expanded.count < pixels.sizeC {
                let remaining = pixels.sizeC - expanded.count
                let sampleCount = min(channel.samplesPerPixel, remaining)
                let baseName = channel.name?.isEmpty == false ? channel.name! : nil

                for sample in 0..<sampleCount {
                    let displayIndex = expanded.count
                    let isInterleaved = sampleCount > 1
                    expanded.append(TIFFChannel(
                        index: displayIndex,
                        idString: isInterleaved ? channel.id.map { "\($0):\(sample)" } : channel.id,
                        name: sampleName(
                            baseName: baseName,
                            displayIndex: displayIndex,
                            sample: sample,
                            sampleCount: sampleCount,
                            isOnlyOMEChannel: delegate.channels.count == 1
                        ),
                        color: channel.color,
                        sourceChannelIndex: sourceC,
                        sampleIndex: isInterleaved ? sample : nil,
                        samplesPerPixel: channel.samplesPerPixel
                    ))
                }
                sourceC += channel.samplesPerPixel
            }

            while expanded.count < pixels.sizeC {
                let index = expanded.count
                expanded.append(TIFFChannel(
                    index: index,
                    idString: nil,
                    name: "Channel \(index + 1)",
                    color: nil,
                    sourceChannelIndex: index,
                    sampleIndex: nil,
                    samplesPerPixel: 1
                ))
            }
            channels = expanded
        }

        return OMEMetadata(
            sizeX: pixels.sizeX,
            sizeY: pixels.sizeY,
            sizeZ: pixels.sizeZ,
            sizeC: pixels.sizeC,
            sizeT: pixels.sizeT,
            dimensionOrder: pixels.dimensionOrder,
            pixelType: pixels.pixelType,
            significantBits: pixels.significantBits,
            physicalSizeX: pixels.physicalSizeX,
            physicalSizeY: pixels.physicalSizeY,
            physicalSizeXUnit: pixels.physicalSizeXUnit,
            physicalSizeYUnit: pixels.physicalSizeYUnit,
            channels: channels,
            tiffData: delegate.tiffData
        )
    }

    private static func sampleName(
        baseName: String?,
        displayIndex: Int,
        sample: Int,
        sampleCount: Int,
        isOnlyOMEChannel: Bool
    ) -> String {
        guard sampleCount > 1 else { return baseName ?? "Channel \(displayIndex + 1)" }
        let componentNames = ["Red", "Green", "Blue", "Alpha"]
        let component = sample < componentNames.count
            ? componentNames[sample]
            : "Component \(sample + 1)"
        guard let baseName, !isOnlyOMEChannel else { return component }
        return "\(baseName) – \(component)"
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Pixels {
            let sizeX: Int
            let sizeY: Int
            let sizeZ: Int
            let sizeC: Int
            let sizeT: Int
            let dimensionOrder: String
            let pixelType: String?
            let significantBits: Int?
            let physicalSizeX: Double?
            let physicalSizeY: Double?
            let physicalSizeXUnit: String?
            let physicalSizeYUnit: String?
        }

        struct Channel {
            let id: String?
            let name: String?
            let color: UInt32?
            let samplesPerPixel: Int
        }

        var pixels: Pixels?
        var channels: [Channel] = []
        var tiffData: [OMETiffData] = []
        private var insideFirstImage = false
        private var imageDepth = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "Image" {
                if pixels == nil && !insideFirstImage {
                    insideFirstImage = true
                    imageDepth = 1
                } else if insideFirstImage {
                    imageDepth += 1
                }
                return
            }
            guard insideFirstImage else { return }

            switch name {
            case "Pixels":
                guard pixels == nil,
                      let sizeX = int(attributeDict["SizeX"]),
                      let sizeY = int(attributeDict["SizeY"]) else { return }
                pixels = Pixels(
                    sizeX: sizeX,
                    sizeY: sizeY,
                    sizeZ: max(1, int(attributeDict["SizeZ"]) ?? 1),
                    sizeC: max(1, int(attributeDict["SizeC"]) ?? 1),
                    sizeT: max(1, int(attributeDict["SizeT"]) ?? 1),
                    dimensionOrder: attributeDict["DimensionOrder"] ?? "XYZCT",
                    pixelType: attributeDict["Type"],
                    significantBits: int(attributeDict["SignificantBits"]),
                    physicalSizeX: double(attributeDict["PhysicalSizeX"]),
                    physicalSizeY: double(attributeDict["PhysicalSizeY"]),
                    physicalSizeXUnit: attributeDict["PhysicalSizeXUnit"],
                    physicalSizeYUnit: attributeDict["PhysicalSizeYUnit"]
                )
            case "Channel":
                channels.append(Channel(
                    id: attributeDict["ID"],
                    name: attributeDict["Name"],
                    color: unsignedColor(attributeDict["Color"]),
                    samplesPerPixel: max(1, int(attributeDict["SamplesPerPixel"]) ?? 1)
                ))
            case "TiffData":
                tiffData.append(OMETiffData(
                    ifd: max(0, int(attributeDict["IFD"]) ?? 0),
                    firstC: max(0, int(attributeDict["FirstC"]) ?? 0),
                    firstZ: max(0, int(attributeDict["FirstZ"]) ?? 0),
                    firstT: max(0, int(attributeDict["FirstT"]) ?? 0),
                    planeCount: int(attributeDict["PlaneCount"])
                ))
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "Image", insideFirstImage {
                imageDepth -= 1
                if imageDepth == 0 { insideFirstImage = false }
            }
        }

        private func int(_ value: String?) -> Int? {
            value.flatMap(Int.init)
        }

        private func double(_ value: String?) -> Double? {
            value.flatMap(Double.init)
        }

        private func unsignedColor(_ value: String?) -> UInt32? {
            guard let value, let signed = Int64(value) else { return nil }
            return UInt32(truncatingIfNeeded: signed)
        }
    }
}
