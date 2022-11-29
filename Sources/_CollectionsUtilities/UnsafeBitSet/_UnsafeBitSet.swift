//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Collections open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/// An unsafe-unowned bitset view over `UInt` storage, providing bit set
/// primitives.
@frozen
public struct _UnsafeBitSet {
  /// An unsafe-unowned storage view.
  public let _words: UnsafeBufferPointer<_Word>

#if DEBUG
  /// True when this handle does not support table mutations.
  /// (This is only checked in debug builds.)
  @usableFromInline
  internal let _mutable: Bool
#endif

  @inlinable
  @inline(__always)
  public func ensureMutable() {
#if DEBUG
    assert(_mutable)
#endif
  }

  @inlinable
  @inline(__always)
  public var _mutableWords: UnsafeMutableBufferPointer<_Word> {
    ensureMutable()
    return UnsafeMutableBufferPointer(mutating: _words)
  }

  @inlinable
  @inline(__always)
  public init(
    words: UnsafeBufferPointer<_Word>,
    mutable: Bool
  ) {
    assert(words.baseAddress != nil)
    self._words = words
#if DEBUG
    self._mutable = mutable
#endif
  }

  @inlinable
  @inline(__always)
  public init(
    words: UnsafeMutableBufferPointer<_Word>,
    mutable: Bool
  ) {
    self.init(words: UnsafeBufferPointer(words), mutable: mutable)
  }
}

extension _UnsafeBitSet {
  @inlinable
  @inline(__always)
  public var wordCount: Int {
    _words.count
  }
}

extension _UnsafeBitSet {
  @inlinable
  @inline(__always)
  public static func withTemporaryBitSet<R>(
    capacity: Int,
    run body: (inout _UnsafeBitSet) throws -> R
  ) rethrows -> R {
    let wordCount = _UnsafeBitSet.wordCount(forCapacity: UInt(capacity))
    return try withTemporaryBitSet(wordCount: wordCount, run: body)
  }

  @inlinable
  @inline(__always)
  public static func withTemporaryBitSet<R>(
    wordCount: Int,
    run body: (inout Self) throws -> R
  ) rethrows -> R {
    var result: R?
    try _withTemporaryBitSet(wordCount: wordCount) { bitset in
      result = try body(&bitset)
    }
    return result!
  }

  @inline(never)
  public static func _withTemporaryBitSet(
    wordCount: Int,
    run body: (inout Self) throws -> Void
  ) rethrows {
    try _withTemporaryUninitializedBitSet(wordCount: wordCount) { handle in
      handle._mutableWords.initialize(repeating: .empty)
      try body(&handle)
    }
  }

  internal static func _withTemporaryUninitializedBitSet(
    wordCount: Int,
    run body: (inout Self) throws -> Void
  ) rethrows {
    assert(wordCount >= 0)
#if compiler(>=5.6)
    return try withUnsafeTemporaryAllocation(
      of: _Word.self, capacity: wordCount
    ) { words in
      var bitset = Self(words: words, mutable: true)
      return try body(&bitset)
    }
#else
    if wordCount <= 2 {
      var buffer: (_Word, _Word) = (.empty, .empty)
      return try withUnsafeMutablePointer(to: &buffer) { p in
        // Homogeneous tuples are layout-compatible with their component type.
        let start = UnsafeMutableRawPointer(p)
          .assumingMemoryBound(to: _Word.self)
        let words = UnsafeMutableBufferPointer(start: start, count: wordCount)
        var bitset = Self(words: words, mutable: true)
        return try body(&bitset)
      }
    }
    let words = UnsafeMutableBufferPointer<_Word>.allocate(capacity: wordCount)
    defer { words.deallocate() }
    var bitset = Self(words: words, mutable: true)
    return try body(&bitset)
#endif
  }
}

extension _UnsafeBitSet {
  @_effects(readnone)
  @inline(__always)
  public static func wordCount(forCapacity capacity: UInt) -> Int {
    _Word.wordCount(forBitCount: capacity)
  }

  public var capacity: UInt {
    @inline(__always)
    get {
      UInt(wordCount &* _Word.capacity)
    }
  }

  @inline(__always)
  internal func isWithinBounds(_ element: UInt) -> Bool {
    element < capacity
  }

  @inline(__always)
  public func contains(_ element: UInt) -> Bool {
    let (word, bit) = Index(element).split
    guard word < wordCount else { return false }
    return _words[word].contains(bit)
  }

  @_effects(releasenone)
  @discardableResult
  public mutating func insert(_ element: UInt) -> Bool {
    ensureMutable()
    assert(isWithinBounds(element))
    let index = Index(element)
    return _mutableWords[index.word].insert(index.bit)
  }

  @_effects(releasenone)
  @discardableResult
  public mutating func remove(_ element: UInt) -> Bool {
    ensureMutable()
    let index = Index(element)
    if index.word >= _words.count { return false }
    return _mutableWords[index.word].remove(index.bit)
  }

  @_effects(releasenone)
  public mutating func update(_ member: UInt, to newValue: Bool) -> Bool {
    ensureMutable()
    let (w, b) = Index(member).split
    _mutableWords[w].update(b, to: newValue)
    return w == _words.count &- 1
  }

  @_effects(releasenone)
  public mutating func insertAll(upTo max: UInt) {
    assert(max <= capacity)
    guard max > 0 else { return }
    let (w, b) = Index(max).split
    for i in 0 ..< w {
      _mutableWords[i] = .allBits
    }
    if b > 0 {
      _mutableWords[w].insertAll(upTo: b)
    }
  }

  @_alwaysEmitIntoClient
  @inline(__always)
  @discardableResult
  public mutating func insert(_ element: Int) -> Bool {
    precondition(element >= 0)
    return insert(UInt(bitPattern: element))
  }

  @_alwaysEmitIntoClient
  @inline(__always)
  @discardableResult
  public mutating func remove(_ element: Int) -> Bool {
    guard element >= 0 else { return false }
    return remove(UInt(bitPattern: element))
  }

  @_alwaysEmitIntoClient
  @inline(__always)
  public mutating func insertAll(upTo max: Int) {
    precondition(max >= 0)
    return insertAll(upTo: UInt(bitPattern: max))
  }
}

extension _UnsafeBitSet: Sequence {
  public typealias Element = UInt

  @inlinable
  @inline(__always)
  public var underestimatedCount: Int {
    count // FIXME: really?
  }

  @inlinable
  @inline(__always)
  public func makeIterator() -> Iterator {
    return Iterator(self)
  }

  @frozen
  public struct Iterator: IteratorProtocol {
    @usableFromInline
    internal let _bitset: _UnsafeBitSet

    @usableFromInline
    internal var _index: Int

    @usableFromInline
    internal var _word: _Word

    @inlinable
    internal init(_ bitset: _UnsafeBitSet) {
      self._bitset = bitset
      self._index = 0
      self._word = bitset.wordCount > 0 ? bitset._words[0] : .empty
    }

    @_effects(releasenone)
    public mutating func next() -> UInt? {
      if let bit = _word.next() {
        return Index(word: _index, bit: bit).value
      }
      while (_index + 1) < _bitset.wordCount {
        _index += 1
        _word = _bitset._words[_index]
        if let bit = _word.next() {
          return Index(word: _index, bit: bit).value
        }
      }
      return nil
    }
  }
}

extension _UnsafeBitSet: BidirectionalCollection {
  @inlinable
  @inline(__always)
  public var count: Int {
    _words.reduce(0) { $0 + $1.count }
  }

  @inlinable
  @inline(__always)
  public var isEmpty: Bool {
    _words.firstIndex(where: { !$0.isEmpty }) == nil
  }

  @inlinable
  public var startIndex: Index {
    let word = _words.firstIndex { !$0.isEmpty }
    guard let word = word else { return endIndex }
    return Index(word: word, bit: _words[word].firstMember!)
  }

  @inlinable
  public var endIndex: Index {
    Index(word: wordCount, bit: 0)
  }
  
  @inlinable
  public subscript(position: Index) -> UInt {
    position.value
  }

  @_effects(releasenone)
  public func index(after index: Index) -> Index {
    precondition(index < endIndex, "Index out of bounds")
    var word = index.word
    var w = _words[word]
    w.removeAll(through: index.bit)
    while w.isEmpty {
      word += 1
      guard word < wordCount else {
        return Index(word: wordCount, bit: 0)
      }
      w = _words[word]
    }
    return Index(word: word, bit: w.firstMember!)
  }

  @_effects(releasenone)
  public func index(before index: Index) -> Index {
    precondition(index <= endIndex, "Index out of bounds")
    var word = index.word
    var w: _Word
    if index.bit > 0 {
      w = _words[word]
      w.removeAll(from: index.bit)
    } else {
      w = .empty
    }
    while w.isEmpty {
      word -= 1
      precondition(word >= 0, "Can't advance below startIndex")
      w = _words[word]
    }
    return Index(word: word, bit: w.lastMember!)
  }
  
  @_effects(releasenone)
  public func distance(from start: Index, to end: Index) -> Int {
    precondition(start <= endIndex && end <= endIndex, "Index out of bounds")
    let isNegative = end < start
    let (start, end) = (Swift.min(start, end), Swift.max(start, end))
    
    let (w1, b1) = start.split
    let (w2, b2) = end.split
    
    if w1 == w2 {
      guard w1 < wordCount else { return 0 }
      let mask = _Word(from: b1, to: b2)
      let c = _words[w1].intersection(mask).count
      return isNegative ? -c : c
    }
    
    var c = 0
    var w = w1
    guard w < wordCount else { return 0 }
    
    c &+= _words[w].subtracting(_Word(upTo: b1)).count
    w &+= 1
    while w < w2 {
      c &+= _words[w].count
      w &+= 1
    }
    guard w < wordCount else { return isNegative ? -c : c }
    c &+= _words[w].intersection(_Word(upTo: b2)).count
    return isNegative ? -c : c
  }
  
  @_effects(releasenone)
  public func index(_ i: Index, offsetBy distance: Int) -> Index {
    precondition(i <= endIndex, "Index out of bounds")
    precondition(i == endIndex || contains(i.value), "Invalid index")
    guard distance != 0 else { return i }
    var remaining = distance.magnitude
    if distance > 0 {
      var (w, b) = i.split
      precondition(w < wordCount, "Index out of bounds")
      if let v = _words[w].subtracting(_Word(upTo: b)).nthElement(&remaining) {
        return Index(word: w, bit: v)
      }
      while true {
        w &+= 1
        guard w < wordCount else { break }
        if let v = _words[w].nthElement(&remaining) {
          return Index(word: w, bit: v)
        }
      }
      precondition(remaining == 0, "Index out of bounds")
      return endIndex
    }

    // distance < 0
    remaining -= 1
    var (w, b) = i.endSplit
    if w < wordCount {
      if let v = _words[w].intersection(_Word(upTo: b)).nthElementFromEnd(&remaining) {
        return Index(word: w, bit: v)
      }
    }
    while true {
      precondition(w > 0, "Index out of bounds")
      w &-= 1
      if let v = _words[w].nthElementFromEnd(&remaining) {
        return Index(word: w, bit: v)
      }
    }
  }
  
  @_effects(releasenone)
  public func index(
    _ i: Index, offsetBy distance: Int, limitedBy limit: Index
  ) -> Index? {
    precondition(i <= endIndex && limit <= endIndex, "Index out of bounds")
    precondition(i == endIndex || contains(i.value), "Invalid index")
    guard distance != 0 else { return i }
    var remaining = distance.magnitude
    if distance > 0 {
      guard i <= limit else {
        return self.index(i, offsetBy: distance)
      }
      var (w, b) = i.split
      if w < wordCount,
         let v = _words[w].subtracting(_Word(upTo: b)).nthElement(&remaining)
      {
        let r = Index(word: w, bit: v)
        return r <= limit ? r : nil
      }
      let maxWord = Swift.min(wordCount - 1, limit.word)
      while w < maxWord {
        w &+= 1
        if let v = _words[w].nthElement(&remaining) {
          let r = Index(word: w, bit: v)
          return r <= limit ? r : nil
        }
      }
      return remaining == 0 && limit == endIndex ? endIndex : nil
    }
    
    // distance < 0
    guard i >= limit else {
      return self.index(i, offsetBy: distance)
    }
    remaining &-= 1
    var (w, b) = i.endSplit
    if w < wordCount {
      if let v = _words[w].intersection(_Word(upTo: b)).nthElementFromEnd(&remaining) {
        let r = Index(word: w, bit: v)
        return r >= limit ? r : nil
      }
    }
    let minWord = limit.word
    while w > minWord {
      w &-= 1
      if let v = _words[w].nthElementFromEnd(&remaining) {
        let r = Index(word: w, bit: v)
        return r >= limit ? r : nil
      }
    }
    return nil
  }
}
