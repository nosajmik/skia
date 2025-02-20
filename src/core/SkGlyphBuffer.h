/*
 * Copyright 2019 Google Inc.
 *
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

#ifndef SkGlyphBuffer_DEFINED
#define SkGlyphBuffer_DEFINED

#include "src/core/SkEnumerate.h"
#include "src/core/SkGlyph.h"
#include "src/core/SkZip.h"

#include <climits>

struct SkGlyphPositionRoundingSpec;
class SkPath;
class SkDrawable;

namespace sktext {
class StrikeForGPU;
}  // namespace sktext

// SkSourceGlyphBuffer is the source of glyphs between the different stages of glyph drawing.
// It starts with the glyphs and positions from the SkGlyphRun as the first source. When glyphs
// are reject by a stage they become the source for the next stage.
class SkSourceGlyphBuffer {
public:
    SkSourceGlyphBuffer() = default;

    void setSource(SkZip<const SkGlyphID, const SkPoint> source) {
        this->~SkSourceGlyphBuffer();
        new (this) SkSourceGlyphBuffer{source};
    }

    void reset();

    void reject(size_t index) {
        SkASSERT(index < fSource.size());
        if (!this->sourceIsRejectBuffers()) {
            // Need to expand the buffers for first use. All other reject sets will be fewer than
            // this one.
            auto [glyphID, pos] = fSource[index];
            fRejectedGlyphIDs.push_back(glyphID);
            fRejectedPositions.push_back(pos);
            fRejectSize++;
        } else {
            SkASSERT(fRejectSize < fRejects.size());
            fRejects[fRejectSize++] = fSource[index];
        }
    }

    SkZip<const SkGlyphID, const SkPoint> flipRejectsToSource() {
        fRejects = SkMakeZip(fRejectedGlyphIDs, fRejectedPositions).first(fRejectSize);
        fSource = fRejects;
        fRejectSize = 0;
        return fSource;
    }

    SkZip<const SkGlyphID, const SkPoint> source() const { return fSource; }

private:
    SkSourceGlyphBuffer(const SkZip<const SkGlyphID, const SkPoint>& source) {
        fSource = source;
    }
    bool sourceIsRejectBuffers() const {
        return fSource.get<0>().data() == fRejectedGlyphIDs.data();
    }

    SkZip<const SkGlyphID, const SkPoint> fSource;
    size_t fRejectSize{0};

    SkZip<SkGlyphID, SkPoint> fRejects;
    SkSTArray<4, SkGlyphID> fRejectedGlyphIDs;
    SkSTArray<4, SkPoint> fRejectedPositions;
};

// A memory format that allows an SkPackedGlyphID, SkGlyph*, and SkPath* to occupy the same
// memory. This allows SkPackedGlyphIDs as input, and SkGlyph*/SkPath* as output using the same
// memory.
class SkGlyphVariant {
public:
    SkGlyphVariant() : fV{nullptr} { }
    SkGlyphVariant& operator= (SkPackedGlyphID packedID) {
        fV.packedID = packedID;
        SkDEBUGCODE(fTag = kPackedID);
        return *this;
    }
    SkGlyphVariant& operator= (const SkGlyph* glyph) {
        fV.glyph = glyph;
        SkDEBUGCODE(fTag = kGlyph);
        return *this;
    }

    const SkGlyph* glyph() const {
        SkASSERT(fTag == kGlyph);
        return fV.glyph;
    }
    SkPackedGlyphID packedID() const {
        SkASSERT(fTag == kPackedID);
        return fV.packedID;
    }

    operator SkPackedGlyphID()  const { return this->packedID(); }
    operator const SkGlyph*()   const { return this->glyph();    }

private:
    union {
        const SkGlyph* glyph;
        SkPackedGlyphID packedID;
    } fV;

#ifdef SK_DEBUG
    enum {
        kEmpty,
        kPackedID,
        kGlyph,
    } fTag{kEmpty};
#endif
};

// A buffer for converting SkPackedGlyph to SkGlyph*s. Initially the buffer contains
// SkPackedGlyphIDs, but those are used to lookup SkGlyph*s which are then copied over the
// SkPackedGlyphIDs.
class SkDrawableGlyphBuffer {
public:
    void ensureSize(int size);

    // Load the buffer with SkPackedGlyphIDs and positions at (0, 0) ready to finish positioning
    // during drawing.
    void startSource(const SkZip<const SkGlyphID, const SkPoint>& source);

    void startSourceWithMatrixAdjustment(
            const SkZip<const SkGlyphID, const SkPoint>& source, const SkMatrix& creationMatrix);

    // Load the buffer with SkPackedGlyphIDs, calculating positions, so they can be constant.
    //
    // The positions are calculated integer positions in devices space, and the mapping of
    // the source origin through the initial matrix is returned. It is given that these positions
    // are only reused when the blob is translated by an integral amount. Thus, the shifted
    // positions are given by the following equation where (ix, iy) is the integer positions of
    // the glyph, initialMappedOrigin is (0,0) in source mapped to the device using the initial
    // matrix, and newMappedOrigin is (0,0) in source mapped to the device using the current
    // drawing matrix.
    //
    //    (ix', iy') = (ix, iy) + round(newMappedOrigin - initialMappedOrigin)
    //
    // In theory, newMappedOrigin - initialMappedOrigin should be integer, but the vagaries of
    // floating point don't guarantee that, so force it to integer.
    //
    // N.B. The positionMatrix is already translated by the origin of the glyph run list.
    void startDevicePositioning(
            const SkZip<const SkGlyphID, const SkPoint>& source,
            const SkMatrix& positionMatrix,
            const SkGlyphPositionRoundingSpec& roundingSpec);

    SkString dumpInput() const;

    // The input of SkPackedGlyphIDs
    SkZip<SkGlyphVariant, SkPoint> input() {
        SkASSERT(fPhase == kInput);
        SkDEBUGCODE(fPhase = kProcess);
        return SkZip<SkGlyphVariant, SkPoint>{
                SkToSizeT(fInputSize), fMultiBuffer.get(), fPositions};
    }

    // Store the glyph in the next slot, using the position information located at index from.
    void accept(SkGlyph* glyph, int from) {
        SkASSERT(fPhase == kProcess);
        SkASSERT(fAcceptedSize <= from);
        fPositions[fAcceptedSize] = fPositions[from];
        fMultiBuffer[fAcceptedSize] = glyph;
        fFormats[fAcceptedSize] = glyph->maskFormat();
        fAcceptedSize++;
    }

    void accept(SkPackedGlyphID glyphID, SkPoint position, SkMask::Format format) {
        SkASSERT(fPhase == kProcess);
        fPositions[fAcceptedSize] = position;
        fMultiBuffer[fAcceptedSize] = glyphID;
        fFormats[fAcceptedSize] = format;
        fAcceptedSize++;
    }

    void accept(SkPackedGlyphID glyphID, SkPoint position) {
        SkASSERT(fPhase == kProcess);
        fPositions[fAcceptedSize] = position;
        fMultiBuffer[fAcceptedSize] = glyphID;
        fAcceptedSize++;
    }

    // The result after a series of `accept` of accepted SkGlyph* or SkPath*.
    SkZip<SkGlyphVariant, SkPoint> accepted() {
        SkASSERT(fPhase == kProcess);
        SkDEBUGCODE(fPhase = kDraw);
        return SkZip<SkGlyphVariant, SkPoint>{
                SkToSizeT(fAcceptedSize), fMultiBuffer.get(), fPositions};
    }

    SkZip<SkGlyphVariant, SkPoint, SkMask::Format> acceptedWithMaskFormat() {
        SkASSERT(fPhase == kProcess);
        SkDEBUGCODE(fPhase = kDraw);
        return SkZip<SkGlyphVariant, SkPoint, SkMask::Format>{
                SkToSizeT(fAcceptedSize), fMultiBuffer.get(), fPositions, fFormats};
    }

    bool empty() const {
        SkASSERT(fPhase == kProcess || fPhase == kDraw);
        return fAcceptedSize == 0;
    }

    void reset();

    template <typename Fn>
    void forEachInput(Fn&& fn) {
        for (auto [i, packedID, pos] : SkMakeEnumerate(this->input())) {
            fn(i, packedID.packedID(), pos);
        }
    }

private:
    int fMaxSize{0};
    int fInputSize{0};
    int fAcceptedSize{0};
    SkAutoTArray<SkGlyphVariant> fMultiBuffer;
    skia_private::AutoTMalloc<SkPoint> fPositions;
    skia_private::AutoTMalloc<SkMask::Format> fFormats;

#ifdef SK_DEBUG
    enum {
        kReset,
        kInput,
        kProcess,
        kDraw
    } fPhase{kReset};
#endif
};
#endif  // SkGlyphBuffer_DEFINED
