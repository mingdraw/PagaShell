/// A circular buffer in which elements know their index in the buffer.
class IndexAwareCircularBuffer<T extends IndexedItem> {
  /// Creates a new circular list with the specified [maxLength].
  IndexAwareCircularBuffer(int maxLength)
    : _array = List<T?>.filled(maxLength, null);

  /// Fixed-capacity backing storage.
  final List<T?> _array;

  /// The number of elements in the list. This is always less than or equal to
  /// the backing storage capacity.
  var _length = 0;

  /// The index of the first element in [_array].
  var _startIndex = 0;

  /// The start index of this list, including items that has been dropped in
  /// overflow
  var _absoluteStartIndex = 0;

  /// Gets the cyclic index for the specified regular index. The cyclic index
  /// can then be used on the backing array to get the element associated with
  /// the regular index.
  @pragma('vm:prefer-inline')
  int _getCyclicIndex(int index) {
    return (_startIndex + index) % _array.length;
  }

  /// Removes the element at [index] from the list.
  @pragma('vm:prefer-inline')
  void _dropChild(int index) {
    final cyclicIndex = _getCyclicIndex(index);
    _array[cyclicIndex]?._detach();
    _array[cyclicIndex] = null;
  }

  /// Adds the specified [child] to the list at the specified [index].
  @pragma('vm:prefer-inline')
  void _adoptChild(int index, T child) {
    final cyclicIndex = _getCyclicIndex(index);
    _array[cyclicIndex]?._detach();
    _array[cyclicIndex] = child.._attach(this, index);
  }

  /// Gets the element at the specified [index] in the list.
  @pragma('vm:prefer-inline')
  T? _getChild(int index) {
    return _array[_getCyclicIndex(index)];
  }

  /// Number of elements in the list.
  int get length {
    return _length;
  }

  List<T> toList() => List.generate(length, (index) => this[index]);

  /// Iterates over the list and calls [callback] for each element.
  void forEach(void Function(T item) callback) {
    final length = _length;
    for (int i = 0; i < length; i++) {
      callback(_getChild(i)!);
    }
  }

  /// Gets the element at the specified [index] in the list. Throws if the
  /// index is out of bounds.
  T operator [](int index) {
    RangeError.checkValueInInterval(index, 0, length - 1, 'index');
    return _getChild(index)!;
  }

  /// Removes all elements from the list.
  void clear() {
    for (var i = 0; i < _length; i++) {
      _dropChild(i);
    }
    _startIndex = 0;
    _length = 0;
  }

  /// Adds [value] to the end of the list. May cause the first element to be
  /// trimmed if the list is full.
  void push(T value) {
    _adoptChild(_length, value);

    if (_length == _array.length) {
      // When the list is full, we trim the first element
      _startIndex++;
      _absoluteStartIndex++;
      if (_startIndex == _array.length) {
        _startIndex = 0;
      }
    } else {
      // When the list is not full, we just increase the length
      _length++;
    }
  }

  /// Removes and returns the last value on the list, throws if the list is
  /// empty.
  T pop() {
    assert(_length > 0, 'Cannot pop from an empty list');
    final result = _getChild(_length - 1);
    _dropChild(_length - 1);
    _length--;
    return result!;
  }

  /// Removes the first [count] elements and advances the buffer's start index
  /// without moving the remaining elements in the backing storage.
  void trimStart(int count) {
    if (count > _length) count = _length;
    for (var i = 0; i < count; i++) {
      _dropChild(i);
    }
    _startIndex += count;
    _absoluteStartIndex += count;
    _startIndex %= _array.length;
    _length -= count;
  }
}

mixin IndexedItem {
  IndexAwareCircularBuffer? _owner;

  int? _absoluteIndex;

  /// The index of this item in the buffer. Must only be accessed when
  /// [attached] is true.
  int get index => _absoluteIndex! - _owner!._absoluteStartIndex;

  /// Whether this item is currently stored in a buffer.
  bool get attached => _owner != null;

  /// Sets the owner and index of this item. This is called by the buffer when
  /// the item is adopted.
  void _attach(IndexAwareCircularBuffer owner, int index) {
    _owner = owner;
    _absoluteIndex = owner._absoluteStartIndex + index;
  }

  /// Marks this item as detached from a buffer. This is called after the item
  /// has been removed from the buffer.
  void _detach() {
    _owner = null;
    _absoluteIndex = null;
  }
}
