//
//  TIFFIndexBuilder.swift
//  CellAnnotator
//

import Foundation

enum TIFFIndexBuilder {
    enum IndexError: LocalizedError {
        case invalidHeader
        case unsupportedOffsetSize
        case corruptDirectory
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .invalidHeader: return "This file does not have a valid TIFF header."
            case .unsupportedOffsetSize: return "This BigTIFF uses an unsupported offset size."
            case .corruptDirectory: return "A TIFF image directory is corrupt or outside the file."
            case .invalidDimensions: return "The TIFF does not report valid image dimensions."
            }
        }
    }

    static func build(url: URL, imageSourceFrames: [TIFFFrame]) throws -> TIFFImageIndex {
        let inventory = try TIFFBinaryInventory(url: url).read()
        guard let largest = inventory.ifds.max(by: {
            $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }), largest.pixelWidth > 0, largest.pixelHeight > 0 else {
            throw IndexError.invalidDimensions
        }

        let ome = inventory.omeXML.flatMap { try? OMEXMLParser.parse($0) }
        let sizeX = ome?.sizeX ?? largest.pixelWidth
        let sizeY = ome?.sizeY ?? largest.pixelHeight
        let sizeZ = ome?.sizeZ ?? 1
        let sizeT = ome?.sizeT ?? 1
        let baseIFD = inventory.topLevelIFDs.first {
            $0.pixelWidth == sizeX && $0.pixelHeight == sizeY
        }
        let inferredPlaneChannelCount = inferPlaneChannelCount(
            inventory.topLevelIFDs,
            sizeX: sizeX,
            sizeY: sizeY
        )
        let declaredChannels = ome?.channels ?? makeNonOMEChannels(
            planeChannelCount: inferredPlaneChannelCount,
            baseIFD: baseIFD
        )
        let channels = expandInterleavedRGBChannels(
            declaredChannels,
            baseIFD: baseIFD
        )
        let sizeC = max(ome?.sizeC ?? channels.count, channels.count)

        let resolutions = makeResolutions(ifds: inventory.ifds, sizeX: sizeX, sizeY: sizeY)
        let baseMapping = makeBaseMapping(
            topLevelIFDs: inventory.topLevelIFDs,
            ome: ome,
            sizeX: sizeX,
            sizeY: sizeY,
            sizeZ: sizeZ,
            sizeC: ome == nil ? inferredPlaneChannelCount : sizeC,
            sizeT: sizeT
        )
        let ifdByOffset = Dictionary(uniqueKeysWithValues: inventory.ifds.map { ($0.offset, $0) })
        let imageSourceIndexByIFD = resolveImageSourceFrames(
            topLevelIFDs: inventory.topLevelIFDs,
            ifdByOffset: ifdByOffset,
            frames: imageSourceFrames
        )
        var planes: [TIFFPlane] = []

        for (topIndex, logical) in baseMapping.sorted(by: { $0.key < $1.key }) {
            guard topIndex < inventory.topLevelIFDs.count else { continue }
            let base = inventory.topLevelIFDs[topIndex]
            appendPlane(
                ifd: base,
                logical: logical,
                level: levelFor(ifd: base, resolutions: resolutions),
                imageSourceIndex: imageSourceIndexByIFD[base.offset],
                to: &planes
            )

            for offset in flattenedSubIFDs(of: base, byOffset: ifdByOffset) {
                guard let subIFD = ifdByOffset[offset] else { continue }
                appendPlane(
                    ifd: subIFD,
                    logical: logical,
                    level: levelFor(ifd: subIFD, resolutions: resolutions),
                    imageSourceIndex: imageSourceIndexByIFD[subIFD.offset],
                    to: &planes
                )
            }
        }

        // A common non-OME pyramid stores every level in the top-level IFD
        // chain. If the base mapping treated those as channels, remap them as
        // levels of one logical plane.
        if ome == nil, inferredPlaneChannelCount == 1, inventory.topLevelIFDs.count > 1 {
            planes = inventory.topLevelIFDs.enumerated().map { sourceIndex, ifd in
                TIFFPlane(
                    coordinate: TIFFPlaneCoordinate(
                        channel: 0,
                        z: 0,
                        time: 0,
                        level: levelFor(ifd: ifd, resolutions: resolutions)
                    ),
                    ifdOffset: ifd.offset,
                    imageSourceIndex: imageSourceIndexByIFD[ifd.offset],
                    pixelWidth: ifd.pixelWidth,
                    pixelHeight: ifd.pixelHeight
                )
            }
        }

        // Remove duplicate logical mappings while preferring an ImageIO-
        // addressable top-level IFD over an inaccessible duplicate.
        let grouped = Dictionary(grouping: planes, by: \.coordinate)
        planes = grouped.values.compactMap { candidates in
            candidates.first(where: { $0.imageSourceIndex != nil }) ?? candidates.first
        }.sorted {
            if $0.coordinate.time != $1.coordinate.time { return $0.coordinate.time < $1.coordinate.time }
            if $0.coordinate.z != $1.coordinate.z { return $0.coordinate.z < $1.coordinate.z }
            if $0.coordinate.channel != $1.coordinate.channel { return $0.coordinate.channel < $1.coordinate.channel }
            return $0.coordinate.level < $1.coordinate.level
        }

        return TIFFImageIndex(
            sizeX: sizeX,
            sizeY: sizeY,
            sizeZ: sizeZ,
            sizeC: sizeC,
            sizeT: sizeT,
            dimensionOrder: ome?.dimensionOrder ?? "XYZCT",
            byteOrder: inventory.byteOrder,
            pixelType: ome?.pixelType,
            significantBits: ome?.significantBits,
            pixelSize: TIFFPixelSize(
                x: ome?.physicalSizeX,
                y: ome?.physicalSizeY,
                unitX: ome?.physicalSizeXUnit,
                unitY: ome?.physicalSizeYUnit
            ),
            channels: channels,
            resolutions: resolutions,
            ifds: inventory.ifds,
            planes: planes,
            omeXML: inventory.omeXML
        )
    }

    private static func inferPlaneChannelCount(_ ifds: [TIFFIFD], sizeX: Int, sizeY: Int) -> Int {
        let fullSize = ifds.filter { $0.pixelWidth == sizeX && $0.pixelHeight == sizeY }
        guard !fullSize.isEmpty else { return 1 }
        // Interleaved samples share one physical plane. Repeated same-size
        // grayscale IFDs are the best metadata-free indication of planes for
        // separate channels.
        if fullSize.count == 1 { return 1 }
        return fullSize.allSatisfy { $0.samplesPerPixel == 1 } ? fullSize.count : 1
    }

    private static func makeNonOMEChannels(
        planeChannelCount: Int,
        baseIFD: TIFFIFD?
    ) -> [TIFFChannel] {
        let samples = baseIFD?.samplesPerPixel ?? 1
        let isRGB = baseIFD?.photometricInterpretation == 2 && samples >= 3
        if planeChannelCount == 1, isRGB {
            let names = ["Red", "Green", "Blue"]
            return names.enumerated().map { sample, name in
                TIFFChannel(
                    index: sample,
                    idString: nil,
                    name: name,
                    color: nil,
                    sourceChannelIndex: 0,
                    sampleIndex: sample,
                    samplesPerPixel: samples
                )
            }
        }

        return (0..<max(1, planeChannelCount)).map { channel in
            TIFFChannel(
                index: channel,
                idString: nil,
                name: "Channel \(channel + 1)",
                color: nil,
                sourceChannelIndex: channel,
                sampleIndex: nil,
                samplesPerPixel: 1
            )
        }
    }

    /// OME-XML sometimes describes an interleaved color image as one logical
    /// channel named "RGB" even though the referenced TIFF IFD stores three
    /// independently addressable samples. Storage layout must not determine
    /// how display controls are grouped, so expose those samples separately.
    ///
    /// If OME supplies three semantic channel names for the interleaved
    /// samples, preserve them. Otherwise use the conventional component names.
    private static func expandInterleavedRGBChannels(
        _ declaredChannels: [TIFFChannel],
        baseIFD: TIFFIFD?
    ) -> [TIFFChannel] {
        guard let baseIFD,
              baseIFD.photometricInterpretation == 2,
              baseIFD.samplesPerPixel >= 3 else {
            return declaredChannels
        }

        let componentCount = 3
        let alreadyExpanded = declaredChannels.count >= componentCount
            && declaredChannels.prefix(componentCount).enumerated().allSatisfy {
                $0.element.sampleIndex == $0.offset
            }
        if alreadyExpanded { return declaredChannels }

        let hasSemanticComponentNames = declaredChannels.count == componentCount
            && declaredChannels.allSatisfy { $0.sampleIndex == nil }
        let componentNames = ["Red", "Green", "Blue"]
        let sourceChannelIndex = declaredChannels.first?.sourceChannelIndex ?? 0

        return (0..<componentCount).map { sample in
            let declared = hasSemanticComponentNames ? declaredChannels[sample] : nil
            return TIFFChannel(
                index: sample,
                idString: declared?.idString,
                name: declared?.name ?? componentNames[sample],
                color: declared?.color,
                sourceChannelIndex: sourceChannelIndex,
                sampleIndex: sample,
                samplesPerPixel: baseIFD.samplesPerPixel
            )
        }
    }

    private static func makeResolutions(ifds: [TIFFIFD], sizeX: Int, sizeY: Int) -> [TIFFResolution] {
        var seen = Set<String>()
        var sizes = ifds.compactMap { ifd -> (Int, Int)? in
            guard ifd.pixelWidth > 0, ifd.pixelHeight > 0 else { return nil }
            let aspect0 = Double(sizeX) / Double(sizeY)
            let aspect = Double(ifd.pixelWidth) / Double(ifd.pixelHeight)
            guard abs(aspect - aspect0) / max(aspect0, 0.000_001) < 0.02 else { return nil }
            let key = "\(ifd.pixelWidth)x\(ifd.pixelHeight)"
            guard seen.insert(key).inserted else { return nil }
            return (ifd.pixelWidth, ifd.pixelHeight)
        }
        sizes.sort { $0.0 * $0.1 > $1.0 * $1.1 }
        if !sizes.contains(where: { $0.0 == sizeX && $0.1 == sizeY }) {
            sizes.insert((sizeX, sizeY), at: 0)
        }
        return sizes.enumerated().map { level, size in
            TIFFResolution(
                level: level,
                pixelWidth: size.0,
                pixelHeight: size.1,
                downsampleX: Double(sizeX) / Double(size.0),
                downsampleY: Double(sizeY) / Double(size.1)
            )
        }
    }

    private static func levelFor(ifd: TIFFIFD, resolutions: [TIFFResolution]) -> Int {
        resolutions.first {
            $0.pixelWidth == ifd.pixelWidth && $0.pixelHeight == ifd.pixelHeight
        }?.level ?? 0
    }

    private static func makeBaseMapping(
        topLevelIFDs: [TIFFIFD],
        ome: OMEMetadata?,
        sizeX: Int,
        sizeY: Int,
        sizeZ: Int,
        sizeC: Int,
        sizeT: Int
    ) -> [Int: (c: Int, z: Int, t: Int)] {
        guard let ome else {
            var mapping: [Int: (c: Int, z: Int, t: Int)] = [:]
            let full = topLevelIFDs.enumerated().filter {
                $0.element.pixelWidth == sizeX && $0.element.pixelHeight == sizeY
            }
            for (channel, item) in full.enumerated() {
                mapping[item.offset] = (min(channel, max(0, sizeC - 1)), 0, 0)
            }
            if mapping.isEmpty, !topLevelIFDs.isEmpty { mapping[0] = (0, 0, 0) }
            return mapping
        }

        // OME SizeC counts samples, while one interleaved RGB Channel occupies
        // a single TIFF plane. Sequence IFDs using the distinct source-plane
        // C coordinates so RGB components are not mistaken for separate IFDs.
        let sourceChannels = Array(Set(ome.channels.map(\.sourceChannelIndex))).sorted()
        let planeChannels = sourceChannels.isEmpty ? Array(0..<max(1, sizeC)) : sourceChannels
        let planeSizeC = max(1, planeChannels.count)
        let totalPlanes = max(1, sizeZ * planeSizeC * sizeT)
        if ome.tiffData.isEmpty {
            return Dictionary(uniqueKeysWithValues: (0..<min(totalPlanes, topLevelIFDs.count)).map { ordinal in
                let decoded = decodePlane(
                    ordinal: ordinal,
                    sizeZ: sizeZ,
                    sizeC: planeSizeC,
                    sizeT: sizeT,
                    order: ome.dimensionOrder
                )
                return (ordinal, (
                    c: planeChannels[min(decoded.c, planeChannels.count - 1)],
                    z: decoded.z,
                    t: decoded.t
                ))
            })
        }

        var mapping: [Int: (c: Int, z: Int, t: Int)] = [:]
        for (entryIndex, entry) in ome.tiffData.enumerated() {
            let nextIFD = entryIndex + 1 < ome.tiffData.count ? ome.tiffData[entryIndex + 1].ifd : topLevelIFDs.count
            let count = max(1, entry.planeCount ?? max(1, nextIFD - entry.ifd))
            let firstPlaneC = planeChannels.firstIndex(of: entry.firstC) ?? 0
            let start = planeOrdinal(
                c: firstPlaneC,
                z: entry.firstZ,
                t: entry.firstT,
                sizeZ: sizeZ,
                sizeC: planeSizeC,
                sizeT: sizeT,
                order: ome.dimensionOrder
            )
            for delta in 0..<count where entry.ifd + delta < topLevelIFDs.count {
                let decoded = decodePlane(
                    ordinal: (start + delta) % totalPlanes,
                    sizeZ: sizeZ,
                    sizeC: planeSizeC,
                    sizeT: sizeT,
                    order: ome.dimensionOrder
                )
                mapping[entry.ifd + delta] = (
                    c: planeChannels[min(decoded.c, planeChannels.count - 1)],
                    z: decoded.z,
                    t: decoded.t
                )
            }
        }
        return mapping
    }

    private static func dimensionAxes(_ order: String) -> [Character] {
        Array(order.uppercased().filter { "ZCT".contains($0) })
    }

    private static func planeOrdinal(
        c: Int, z: Int, t: Int,
        sizeZ: Int, sizeC: Int, sizeT: Int,
        order: String
    ) -> Int {
        let values: [Character: Int] = ["Z": z, "C": c, "T": t]
        let sizes: [Character: Int] = ["Z": sizeZ, "C": sizeC, "T": sizeT]
        var multiplier = 1
        var ordinal = 0
        for axis in dimensionAxes(order) {
            ordinal += (values[axis] ?? 0) * multiplier
            multiplier *= max(1, sizes[axis] ?? 1)
        }
        return ordinal
    }

    private static func decodePlane(
        ordinal: Int,
        sizeZ: Int, sizeC: Int, sizeT: Int,
        order: String
    ) -> (c: Int, z: Int, t: Int) {
        let sizes: [Character: Int] = ["Z": sizeZ, "C": sizeC, "T": sizeT]
        var remainder = ordinal
        var values: [Character: Int] = ["Z": 0, "C": 0, "T": 0]
        for axis in dimensionAxes(order) {
            let size = max(1, sizes[axis] ?? 1)
            values[axis] = remainder % size
            remainder /= size
        }
        return (values["C"] ?? 0, values["Z"] ?? 0, values["T"] ?? 0)
    }

    private static func appendPlane(
        ifd: TIFFIFD,
        logical: (c: Int, z: Int, t: Int),
        level: Int,
        imageSourceIndex: Int?,
        to planes: inout [TIFFPlane]
    ) {
        planes.append(TIFFPlane(
            coordinate: TIFFPlaneCoordinate(channel: logical.c, z: logical.z, time: logical.t, level: level),
            ifdOffset: ifd.offset,
            imageSourceIndex: imageSourceIndex,
            pixelWidth: ifd.pixelWidth,
            pixelHeight: ifd.pixelHeight
        ))
    }

    private static func flattenedSubIFDs(of root: TIFFIFD, byOffset: [UInt64: TIFFIFD]) -> [UInt64] {
        var result: [UInt64] = []
        var queue = root.subIFDOffsets
        var visited = Set<UInt64>()
        while !queue.isEmpty {
            let offset = queue.removeFirst()
            guard visited.insert(offset).inserted else { continue }
            result.append(offset)
            queue.append(contentsOf: byOffset[offset]?.subIFDOffsets ?? [])
        }
        return result
    }

    private static func resolveImageSourceFrames(
        topLevelIFDs: [TIFFIFD],
        ifdByOffset: [UInt64: TIFFIFD],
        frames: [TIFFFrame]
    ) -> [UInt64: Int] {
        var result: [UInt64: Int] = [:]
        var unused = Set(frames.indices)

        // Prefer the conventional top-level IFD == ImageIO-page mapping.
        for (topIndex, ifd) in topLevelIFDs.enumerated() where unused.contains(topIndex) {
            let frame = frames[topIndex]
            if frame.pixelWidth == ifd.pixelWidth && frame.pixelHeight == ifd.pixelHeight {
                result[ifd.offset] = frame.sourceIndex
                unused.remove(topIndex)
            }
        }

        // Some ImageIO versions also flatten SubIFDs. Resolve remaining IFDs
        // by dimensions and stable inventory order without making the viewer
        // depend on that page order.
        var orderedIFDs: [TIFFIFD] = []
        for base in topLevelIFDs {
            orderedIFDs.append(base)
            orderedIFDs.append(contentsOf: flattenedSubIFDs(of: base, byOffset: ifdByOffset).compactMap { ifdByOffset[$0] })
        }
        for ifd in orderedIFDs where result[ifd.offset] == nil {
            guard let frameIndex = unused.sorted().first(where: {
                frames[$0].pixelWidth == ifd.pixelWidth && frames[$0].pixelHeight == ifd.pixelHeight
            }) else { continue }
            result[ifd.offset] = frames[frameIndex].sourceIndex
            unused.remove(frameIndex)
        }
        return result
    }
}

private final class TIFFBinaryInventory {
    struct Result {
        let topLevelIFDs: [TIFFIFD]
        let ifds: [TIFFIFD]
        let omeXML: String?
        let byteOrder: TIFFByteOrder
    }

    private enum ByteOrder { case little, big }
    private let handle: FileHandle
    private let fileSize: UInt64
    private var byteOrder: ByteOrder = .little
    private var isBigTIFF = false
    private var inlineByteCount = 4

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    deinit { try? handle.close() }

    func read() throws -> Result {
        let header = try readBytes(at: 0, count: 16)
        guard header.count >= 8 else { throw TIFFIndexBuilder.IndexError.invalidHeader }
        if header[0] == 0x49 && header[1] == 0x49 { byteOrder = .little }
        else if header[0] == 0x4d && header[1] == 0x4d { byteOrder = .big }
        else { throw TIFFIndexBuilder.IndexError.invalidHeader }

        let magic = uint16(header, at: 2)
        let firstOffset: UInt64
        switch magic {
        case 42:
            isBigTIFF = false
            inlineByteCount = 4
            firstOffset = UInt64(uint32(header, at: 4))
        case 43:
            guard uint16(header, at: 4) == 8, uint16(header, at: 6) == 0 else {
                throw TIFFIndexBuilder.IndexError.unsupportedOffsetSize
            }
            isBigTIFF = true
            inlineByteCount = 8
            firstOffset = uint64(header, at: 8)
        default:
            throw TIFFIndexBuilder.IndexError.invalidHeader
        }

        var topLevel: [TIFFIFD] = []
        var allByOffset: [UInt64: TIFFIFD] = [:]
        var next = firstOffset
        var topIndex = 0
        var visited = Set<UInt64>()
        while next != 0, visited.insert(next).inserted {
            let parsed = try readIFD(at: next, parent: nil, topLevelIndex: topIndex)
            topLevel.append(parsed.ifd)
            allByOffset[parsed.ifd.offset] = parsed.ifd
            try readSubIFDs(of: parsed.ifd, into: &allByOffset, visited: &visited)
            next = parsed.nextOffset
            topIndex += 1
        }

        var omeXML: String?
        for ifd in topLevel {
            guard let description = try imageDescription(in: ifd.offset) else { continue }
            if description.range(of: "<OME", options: [.caseInsensitive]) != nil {
                omeXML = description
                break
            }
        }
        return Result(
            topLevelIFDs: topLevel,
            ifds: Array(allByOffset.values).sorted { $0.offset < $1.offset },
            omeXML: omeXML,
            byteOrder: byteOrder == .little ? .littleEndian : .bigEndian
        )
    }

    private func readSubIFDs(
        of parent: TIFFIFD,
        into result: inout [UInt64: TIFFIFD],
        visited: inout Set<UInt64>
    ) throws {
        for offset in parent.subIFDOffsets where offset != 0 && visited.insert(offset).inserted {
            let parsed = try readIFD(at: offset, parent: parent.offset, topLevelIndex: nil)
            result[offset] = parsed.ifd
            try readSubIFDs(of: parsed.ifd, into: &result, visited: &visited)
        }
    }

    private struct ParsedIFD {
        let ifd: TIFFIFD
        let nextOffset: UInt64
    }

    private func readIFD(at offset: UInt64, parent: UInt64?, topLevelIndex: Int?) throws -> ParsedIFD {
        guard offset > 0, offset < fileSize else { throw TIFFIndexBuilder.IndexError.corruptDirectory }
        let countWidth = isBigTIFF ? 8 : 2
        let countData = try readBytes(at: offset, count: countWidth)
        let entryCount64 = isBigTIFF ? uint64(countData, at: 0) : UInt64(uint16(countData, at: 0))
        guard entryCount64 <= 4096 else { throw TIFFIndexBuilder.IndexError.corruptDirectory }
        let entryCount = Int(entryCount64)
        let entryWidth = isBigTIFF ? 20 : 12
        let entriesOffset = offset + UInt64(countWidth)
        let entries = try readBytes(at: entriesOffset, count: entryCount * entryWidth)
        let nextOffsetPosition = entriesOffset + UInt64(entryCount * entryWidth)
        let nextData = try readBytes(at: nextOffsetPosition, count: isBigTIFF ? 8 : 4)
        let nextOffset = isBigTIFF ? uint64(nextData, at: 0) : UInt64(uint32(nextData, at: 0))

        var tags: [UInt16: Entry] = [:]
        for index in 0..<entryCount {
            let start = index * entryWidth
            let tag = uint16(entries, at: start)
            let type = uint16(entries, at: start + 2)
            let count = isBigTIFF ? uint64(entries, at: start + 4) : UInt64(uint32(entries, at: start + 4))
            let valueStart = start + (isBigTIFF ? 12 : 8)
            let inline = Data(entries[valueStart..<(valueStart + inlineByteCount)])
            let valueOffset = isBigTIFF ? uint64(entries, at: valueStart) : UInt64(uint32(entries, at: valueStart))
            tags[tag] = Entry(type: type, count: count, inline: inline, valueOffset: valueOffset)
        }

        let width = try integerValues(tags[256]).first.map(Int.init) ?? 0
        let height = try integerValues(tags[257]).first.map(Int.init) ?? 0
        let bits = try integerValues(tags[258]).map(Int.init)
        let subIFDs = try integerValues(tags[330])
        let tileOffsets = try integerValues(tags[324])
        let tileByteCounts = try integerValues(tags[325])
        let stripOffsets = try valueCount(tags[273])
        let stripByteCounts = try valueCount(tags[279])

        let ifd = TIFFIFD(
            offset: offset,
            parentOffset: parent,
            topLevelIndex: topLevelIndex,
            pixelWidth: width,
            pixelHeight: height,
            bitsPerSample: bits,
            sampleFormat: try integerValues(tags[339]).first.map(Int.init),
            samplesPerPixel: try integerValues(tags[277]).first.map(Int.init) ?? 1,
            compression: try integerValues(tags[259]).first.map(Int.init),
            predictor: try integerValues(tags[317]).first.map(Int.init) ?? 1,
            photometricInterpretation: try integerValues(tags[262]).first.map(Int.init),
            planarConfiguration: try integerValues(tags[284]).first.map(Int.init),
            orientation: try integerValues(tags[274]).first.map(Int.init) ?? 1,
            tileWidth: try integerValues(tags[322]).first.map(Int.init),
            tileHeight: try integerValues(tags[323]).first.map(Int.init),
            tileOffsets: tileOffsets,
            tileByteCounts: tileByteCounts,
            stripCount: min(stripOffsets, stripByteCounts),
            subIFDOffsets: subIFDs
        )
        return ParsedIFD(ifd: ifd, nextOffset: nextOffset)
    }

    private struct Entry {
        let type: UInt16
        let count: UInt64
        let inline: Data
        let valueOffset: UInt64
    }

    private func valueCount(_ entry: Entry?) throws -> Int {
        guard let entry else { return 0 }
        return Int(min(entry.count, UInt64(Int.max)))
    }

    private func integerValues(_ entry: Entry?) throws -> [UInt64] {
        guard let entry, entry.count > 0 else { return [] }
        let typeSize: Int
        switch entry.type {
        case 1, 2, 6, 7: typeSize = 1
        case 3, 8: typeSize = 2
        case 4, 9, 11, 13: typeSize = 4
        case 5, 10, 12, 16, 17, 18: typeSize = 8
        default: return []
        }
        guard entry.count <= 10_000_000 else { throw TIFFIndexBuilder.IndexError.corruptDirectory }
        let byteCount64 = entry.count * UInt64(typeSize)
        guard byteCount64 <= UInt64(Int.max) else { throw TIFFIndexBuilder.IndexError.corruptDirectory }
        let byteCount = Int(byteCount64)
        let data = byteCount <= inlineByteCount
            ? Data(entry.inline.prefix(byteCount))
            : try readBytes(at: entry.valueOffset, count: byteCount)
        var values: [UInt64] = []
        values.reserveCapacity(Int(entry.count))
        for index in 0..<Int(entry.count) {
            let position = index * typeSize
            switch typeSize {
            case 1: values.append(UInt64(data[position]))
            case 2: values.append(UInt64(uint16(data, at: position)))
            case 4: values.append(UInt64(uint32(data, at: position)))
            case 8: values.append(uint64(data, at: position))
            default: break
            }
        }
        return values
    }

    private func imageDescription(in ifdOffset: UInt64) throws -> String? {
        let countWidth = isBigTIFF ? 8 : 2
        let countData = try readBytes(at: ifdOffset, count: countWidth)
        let count = Int(isBigTIFF ? uint64(countData, at: 0) : UInt64(uint16(countData, at: 0)))
        let entryWidth = isBigTIFF ? 20 : 12
        let entries = try readBytes(at: ifdOffset + UInt64(countWidth), count: count * entryWidth)
        for index in 0..<count {
            let start = index * entryWidth
            guard uint16(entries, at: start) == 270 else { continue }
            let type = uint16(entries, at: start + 2)
            guard type == 2 else { return nil }
            let valueCount = isBigTIFF ? uint64(entries, at: start + 4) : UInt64(uint32(entries, at: start + 4))
            guard valueCount > 0, valueCount <= 16 * 1024 * 1024 else { return nil }
            let valueStart = start + (isBigTIFF ? 12 : 8)
            let inline = Data(entries[valueStart..<(valueStart + inlineByteCount)])
            let valueOffset = isBigTIFF ? uint64(entries, at: valueStart) : UInt64(uint32(entries, at: valueStart))
            let bytes = Int(valueCount) <= inlineByteCount
                ? Data(inline.prefix(Int(valueCount)))
                : try readBytes(at: valueOffset, count: Int(valueCount))
            return String(data: bytes.prefix { $0 != 0 }, encoding: .utf8)
                ?? String(data: bytes.prefix { $0 != 0 }, encoding: .isoLatin1)
        }
        return nil
    }

    private func readBytes(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw TIFFIndexBuilder.IndexError.corruptDirectory
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw TIFFIndexBuilder.IndexError.corruptDirectory }
        return data
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
        return byteOrder == .little ? a | (b << 8) : (a << 8) | b
    }

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        if byteOrder == .little {
            return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
        }
        return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
    }

    private func uint64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        if byteOrder == .little {
            for index in 0..<8 { value |= UInt64(data[offset + index]) << UInt64(index * 8) }
        } else {
            for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        }
        return value
    }
}
