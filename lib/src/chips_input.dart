import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';

import 'suggestions_box_controller.dart';
import 'text_cursor.dart';

/// Return zero or more values that match the user input.
typedef ChipsInputSuggestions<T> = FutureOr<List<T>> Function(String query);

/// Return a widget to represent the given value.
typedef ChipsBuilder<T> = Widget Function(
  BuildContext context,
  ChipsInputState<T> state,
  T data,
);

const kObjectReplacementChar = 0xFFFD;

extension on TextEditingValue {
  String get normalCharactersText => String.fromCharCodes(
        text.codeUnits.where((ch) => ch != kObjectReplacementChar),
      );

  int get replacementCharactersCount =>
      text.codeUnits.where((ch) => ch == kObjectReplacementChar).length;
}

/// Text field that may contain multiple values.
///
/// Renders as a text field which will contain values based on selections made
/// by the user. Through the use of `findSuggestions()` and
/// `suggestionBuilder()` the textual input from the user will be converted into
/// a list of matching values from which the user may select.
///
/// The `chipBuilder()` is used build widgets to represent the selected values.
/// These are typically `InputChip` since they offer an easy method for the user
/// to delete values, however any widget may be returned.
///
/// See the `ChipsInputState` class for functions to add and remove chips from
/// the widget in a programmatic fashion.
class ChipsInput<T> extends StatefulWidget {
  const ChipsInput({
    Key? key,
    this.initialValue = const [],
    this.decoration = const InputDecoration(),
    this.enabled = true,
    required this.chipBuilder,
    required this.suggestionBuilder,
    required this.findSuggestions,
    required this.onChanged,
    this.maxChips,
    this.textStyle,
    this.maxHeight = 40,
    this.minHeight = 40,
    this.suggestionsBoxMaxHeight,
    this.inputType = TextInputType.text,
    this.textOverflow = TextOverflow.clip,
    this.obscureText = false,
    this.autocorrect = true,
    this.ensureVisible = true,
    this.actionLabel,
    this.inputAction = TextInputAction.done,
    this.keyboardAppearance = Brightness.dark,
    this.textCapitalization = TextCapitalization.none,
    this.autofocus = false,
    this.allowChipEditing = false,
    this.focusNode,
    this.initialSuggestions,
    this.suggestionsBoxElevation = 20,
    this.suggestionsBoxDecoration = const BoxDecoration(),
    this.showKeyboard = true,
    this.controller,
  })  : assert(maxChips == null || initialValue.length <= maxChips),
        super(key: key);

  final InputDecoration decoration;

  /// The style to be applied to the chip's label.
  final TextStyle? textStyle;

  /// If false, prevents editing of the values.
  final bool enabled;

  /// Function for producing suggested values based on text input.
  final ChipsInputSuggestions<T> findSuggestions;

  /// Invoked any time chips are added, edited, or removed.
  final ValueChanged<List<T>> onChanged;

  /// Function to produce a widget to show in the input field.
  final ChipsBuilder<T> chipBuilder;

  /// Function to produce a widget to show in the suggestions overlay.
  final ChipsBuilder<T> suggestionBuilder;

  /// List of initial values, if any.
  final List<T> initialValue;

  /// Maximum number of chips to allow in the field.
  final int? maxChips;

  /// Maximum height for the input field containing the values and cursor.
  ///
  /// This translates directly into the height of the blinking cursor.
  final double maxHeight;

  /// Maximum height for the input field containing the values and cursor.
  ///
  /// This translates directly into the height of the blinking cursor.
  final double minHeight;

  /// Maximum height for the suggestions overlay.
  final double? suggestionsBoxMaxHeight;

  /// Specify type of information for which to optimize the input control.
  final TextInputType inputType;

  /// How overflowing text should be handled.
  final TextOverflow textOverflow;

  /// Whether to hide the text being edited (e.g., for passwords).
  final bool obscureText;

  /// Whether to enable autocorrection.
  final bool autocorrect;

  /// What text to display in the text input control's action button.
  final String? actionLabel;

  /// What kind of action to request for the action button on the IME.
  final TextInputAction inputAction;

  /// The appearance of the keyboard.
  final Brightness keyboardAppearance;

  /// Whether this text field should focus itself if nothing else is already
  /// focused.
  final bool autofocus;

  /// Scroll the parent to make the input field visible, if true.
  final bool ensureVisible;

  /// If true, allow editing a chip value.
  final bool allowChipEditing;

  /// Passed to `Material` as the `elevation` value for the overlay.
  final double suggestionsBoxElevation;

  /// Decoration for the suggestions overlay.
  final BoxDecoration suggestionsBoxDecoration;

  /// Defines the keyboard focus for this widget.
  final FocusNode? focusNode;

  /// Set of values to suggest when field first receives focus.
  final List<T>? initialSuggestions;

  /// If true, show the keyboard when the field receives the focus.
  final bool showKeyboard;

  /// Configures how the platform keyboard will select an uppercase or lowercase
  /// keyboard.
  final TextCapitalization textCapitalization;

  final SuggestionsBoxController? controller;

  @override
  ChipsInputState<T> createState() => ChipsInputState<T>();
}

/// Represents the state of the chips input widget.
///
/// You may use the `selectSuggestion()` and `deleteChip()` functions to add or
/// remove chips from the input field. This can be used when combining
/// `ChipsInput` with other widgets, such as a drop-down selector.
class ChipsInputState<T> extends State<ChipsInput<T>> with TextInputClient {
  Set<T> _chips = <T>{};
  List<T?>? _suggestions;
  final StreamController<List<T?>?> _suggestionsStreamController =
      StreamController<List<T>?>.broadcast();
  late StreamSubscription<bool> _keyboardVisibilityStream;
  int _searchId = 0;
  TextEditingValue _value = TextEditingValue.empty;
  TextInputConnection? _textInputConnection;
  late SuggestionsBoxController _suggestionsBoxController;
  final _layerLink = LayerLink();
  final Map<T?, String> _enteredTexts = <T, String>{};
  T? _selectedSuggestion;
  int _cursorIndex = 0;

  TextInputConfiguration get textInputConfiguration => TextInputConfiguration(
        inputType: widget.inputType,
        obscureText: widget.obscureText,
        autocorrect: widget.autocorrect,
        actionLabel: widget.actionLabel,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        textCapitalization: widget.textCapitalization,
      );

  bool get _hasInputConnection => _textInputConnection?.attached ?? false;

  bool get _hasReachedMaxChips =>
      widget.maxChips != null && _chips.length >= widget.maxChips!;

  FocusNode? _focusNode;
  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_focusNode ??= FocusNode());
  late FocusAttachment _nodeAttachment;

  RenderBox? get renderBox => context.findRenderObject() as RenderBox?;

  bool get _canRequestFocus => widget.enabled;

  @override
  void initState() {
    super.initState();
    initSuggestionsChips();
    _suggestionsBoxController =
        widget.controller ?? SuggestionsBoxController(context);
    _effectiveFocusNode.addListener(_handleFocusChanged);
    _nodeAttachment = _effectiveFocusNode.attach(context);
    _effectiveFocusNode.canRequestFocus = _canRequestFocus;
    _updateTextInputState(replaceText: true);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _initOverlayEntry();
      if (mounted && widget.autofocus) {
        FocusScope.of(context).autofocus(_effectiveFocusNode);
      }
    });
    _keyboardVisibilityStream =
        KeyboardVisibilityController().onChange.listen((bool visible) {
      if (!visible) {
        _suggestionsBoxController.close();
        _focusNode?.unfocus();
      }
    });
  }

  @override
  void dispose() {
    _closeInputConnectionIfNeeded();
    _effectiveFocusNode.removeListener(_handleFocusChanged);
    _focusNode?.dispose();
    _suggestionsStreamController.close();
    _suggestionsBoxController.close();
    _keyboardVisibilityStream.cancel();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_focusNode?.hasFocus ?? false) {
      if (widget.showKeyboard) {
        _openInputConnection();
      }
      _suggestionsBoxController.open();
    } else {
      _closeInputConnectionIfNeeded();
      _suggestionsBoxController.close();
    }
    if (mounted) {
      setState(() {
        // rebuild so that TextCursor is hidden (side-effect?)
      });
    }
  }

  void requestKeyboard() {
    if (_effectiveFocusNode.hasFocus) {
      _openInputConnection();
      _suggestionsBoxController.open();
    } else {
      FocusScope.of(context).requestFocus(_effectiveFocusNode);
    }
  }

  void _initOverlayEntry() {
    _suggestionsBoxController.overlayEntry = OverlayEntry(
      builder: (context) {
        final size = renderBox!.size;
        final renderBoxOffset = renderBox!.localToGlobal(Offset.zero);
        final topAvailableSpace = renderBoxOffset.dy;
        final mq = MediaQuery.of(context);
        final bottomAvailableSpace = mq.size.height -
            mq.viewInsets.bottom -
            renderBoxOffset.dy -
            size.height;

        var suggestionBoxHeight = max(topAvailableSpace, bottomAvailableSpace);
        if (widget.suggestionsBoxMaxHeight != null) {
          suggestionBoxHeight =
              min(suggestionBoxHeight, widget.suggestionsBoxMaxHeight!);
        }
        final showTop = topAvailableSpace > bottomAvailableSpace;
        final compositedTransformFollowerOffset =
            showTop ? Offset(0, -size.height) : Offset.zero;

        return Stack(
          children: [
            ModalBarrier(
              onDismiss: () {
                _suggestionsBoxController.close();
              },
            ),
            StreamBuilder<List<T?>?>(
              stream: _suggestionsStreamController.stream,
              initialData: _suggestions,
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data!.isNotEmpty) {
                  final suggestionsListView = Material(
                    elevation: widget.suggestionsBoxElevation,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: suggestionBoxHeight,
                      ),
                      child: DecoratedBox(
                        decoration: widget.suggestionsBoxDecoration,
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: snapshot.data!.length,
                          itemBuilder: (BuildContext context, int index) {
                            if (_suggestions != null) {
                              final suggestion = _suggestions![index] as T;

                              return ListTile(
                                title: widget.suggestionBuilder(
                                  context,
                                  this,
                                  suggestion,
                                ),
                                selected: _selectedSuggestion == suggestion,
                                selectedTileColor: Colors.grey.withOpacity(0.2),
                                onTap: () => selectSuggestion(suggestion),
                              );
                            } else {
                              return Container();
                            }
                          },
                        ),
                      ),
                    ),
                  );
                  return Positioned(
                    width: size.width,
                    child: CompositedTransformFollower(
                      link: _layerLink,
                      showWhenUnlinked: false,
                      offset: compositedTransformFollowerOffset,
                      child: !showTop
                          ? suggestionsListView
                          : FractionalTranslation(
                              translation: const Offset(0, -1),
                              child: suggestionsListView,
                            ),
                    ),
                  );
                }
                return Container();
              },
            ),
          ],
        );
      },
    );
  }

  /// Add the provided value to the list of values in the widget.
  void selectSuggestion(T data) {
    if (!_hasReachedMaxChips) {
      setState(() => _chips = _chips..add(data));
      if (widget.allowChipEditing) {
        final enteredText = _value.normalCharactersText;
        if (enteredText.isNotEmpty) {
          _enteredTexts[data] = enteredText;
        }
      }
      _updateTextInputState(replaceText: true);
      setState(() {
        _suggestions?.remove(data);

        if (_suggestions?.isNotEmpty ?? false) {
          _selectedSuggestion = _suggestions?.first;
        }
        _cursorIndex += 1;
      });
      _suggestionsStreamController.add(_suggestions);
      if (_hasReachedMaxChips) _suggestionsBoxController.close();
      widget.onChanged(_chips.toList());
    } else {
      _suggestionsBoxController.close();
    }
    widget.onChanged(_chips.toList());
    if (!widget.showKeyboard) {
      _focusNode?.unfocus();
    }
  }

  /// Remove the chip that represents the given value, if any.
  void deleteChip(T data) {
    if (widget.enabled) {
      setState(() {
        _cursorIndex -= 1;
        _chips.remove(data);
        _suggestions?.add(data);
      });
      if (_enteredTexts.containsKey(data)) _enteredTexts.remove(data);
      _updateTextInputState();
      _suggestionsBoxController.overlayEntry?.markNeedsBuild();

      widget.onChanged(_chips.toList());
    }
  }

  void _openInputConnection() {
    if (!_hasInputConnection) {
      _textInputConnection = TextInput.attach(this, textInputConfiguration);
      _textInputConnection!.show();
      _updateTextInputState();
    } else {
      _textInputConnection?.show();
    }

    if (widget.ensureVisible) {
      _scrollToVisible();
    }
  }

  void _scrollToVisible() {
    Future.delayed(const Duration(milliseconds: 300), () {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final renderBox = context.findRenderObject();

        if (renderBox == null || renderBox is! RenderBox) return;
        await Scrollable.of(context)
            .position
            .ensureVisible(renderBox)
            .then((_) async {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _suggestionsBoxController.overlayEntry?.markNeedsBuild();
          });
        });
      });
    });
  }

  Future<void> _onSearchChanged(String value) async {
    final localId = ++_searchId;
    final results = await widget.findSuggestions(value);
    results.removeWhere((element) => _chips.contains(element));

    if (_searchId == localId && mounted) {
      setState(
        () {
          _suggestions = results.where((r) => !_chips.contains(r)).toList();
          _selectedSuggestion =
              (_suggestions?.isNotEmpty ?? false) ? _suggestions!.first : null;
        },
      );
    }
    _suggestionsStreamController.add(_suggestions ?? []);
    if (!_suggestionsBoxController.isOpened && !_hasReachedMaxChips) {
      _suggestionsBoxController.open();
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_hasInputConnection) {
      _textInputConnection!.close();
      _textInputConnection = null;
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    final oldTextEditingValue = _value;
    if (value.text != oldTextEditingValue.text) {
      setState(() => _value = value);
      if (value.replacementCharactersCount <
              oldTextEditingValue.replacementCharactersCount &&
          _chips.isNotEmpty &&
          _cursorIndex > 0) {
        _cursorIndex -= 1;
        final removedChip = _chips.toList()[_cursorIndex];
        setState(
          () => _chips.remove(removedChip),
        );
        widget.onChanged(_chips.toList());
        String putText = '';
        if (widget.allowChipEditing && _enteredTexts.containsKey(removedChip)) {
          putText = _enteredTexts[removedChip] ?? '';
          _enteredTexts.remove(removedChip);
        }
        _updateTextInputState(putText: putText);
      } else if (!kIsWeb) {
        // text input is updated on browser but not elsewhere?
        _updateTextInputState();
      }
      _onSearchChanged(_value.normalCharactersText);
    }
  }

  void _updateTextInputState({bool replaceText = false, String putText = ''}) {
    // update the text every time unconditionally as the text needs to be kept
    // in sync with the the list of values that are changing out-of-band
    final updatedText =
        String.fromCharCodes(_chips.map((_) => kObjectReplacementChar)) +
            (replaceText ? '' : _value.normalCharactersText) +
            putText;
    setState(
      () => _value = TextEditingValue(
        text: updatedText,
        selection: TextSelection.collapsed(offset: updatedText.length),
      ),
    );
    if (!kIsWeb) {
      _closeInputConnectionIfNeeded();
    }
    _textInputConnection ??= TextInput.attach(this, textInputConfiguration);
    if (_textInputConnection?.attached ?? false) {
      _textInputConnection?.setEditingState(_value);
    }
    _textInputConnection?.show();
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
      case TextInputAction.search:
        if (_selectedSuggestion != null) {
          selectSuggestion(_selectedSuggestion as T);
          _onSearchChanged('');
        }

        break;
      default:
        _effectiveFocusNode.unfocus();
        break;
    }
  }

  void initSuggestionsChips() {
    _chips.clear();
    _chips.addAll(widget.initialValue);
    _cursorIndex = _chips.length;
    _suggestions =
        widget.initialSuggestions?.where((r) => !_chips.contains(r)).toList();
    _selectedSuggestion =
        _suggestions?.isNotEmpty == true ? _suggestions!.first : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _effectiveFocusNode.canRequestFocus = _canRequestFocus;
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void didUpdateWidget(covariant ChipsInput<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _effectiveFocusNode.canRequestFocus = _canRequestFocus;
    if (oldWidget.initialSuggestions != widget.initialSuggestions) {
      initSuggestionsChips();
    }
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void connectionClosed() {}

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  Widget build(BuildContext context) {
    _nodeAttachment.reparent();
    final chipsChildren = _chips
        .map<Widget>((data) => widget.chipBuilder(context, this, data))
        .toList();

    final theme = Theme.of(context);

    chipsChildren.insert(
      _cursorIndex,
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: widget.maxHeight,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: Text(
                _value.normalCharactersText,
                maxLines: 1,
                overflow: widget.textOverflow,
                style: widget.textStyle ??
                    theme.textTheme.titleMedium?.copyWith(height: 1.5),
              ),
            ),
            Flexible(
              flex: 0,
              child: TextCursor(resumed: _effectiveFocusNode.hasFocus),
            ),
          ],
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _effectiveFocusNode.unfocus();
          _suggestionsBoxController.close();
        },
        const SingleActivator(LogicalKeyboardKey.arrowDown): () {
          if ((_suggestions?.isNotEmpty ?? false) &&
              _suggestionsBoxController.isOpened) {
            final index = _suggestions?.indexOf(_selectedSuggestion) ?? 0;
            setState(() {
              if (index < _suggestions!.length - 1) {
                _selectedSuggestion = _suggestions?[index + 1];
              } else {
                _selectedSuggestion = _suggestions?[0];
              }
              _suggestionsBoxController.overlayEntry?.markNeedsBuild();
            });
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowUp): () {
          if ((_suggestions?.isNotEmpty ?? false) &&
              _suggestionsBoxController.isOpened) {
            final index = _suggestions?.indexOf(_selectedSuggestion) ?? 0;

            setState(() {
              if (index > 0) {
                _selectedSuggestion = _suggestions?[index - 1];
              } else {
                _selectedSuggestion =
                    _suggestions?[(_suggestions?.length ?? 1) - 1];
              }
              _suggestionsBoxController.overlayEntry?.markNeedsBuild();
            });
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          if (_cursorIndex > 0) {
            setState(() {
              _cursorIndex -= 1;
            });
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          if (_cursorIndex < _chips.length) {
            setState(() {
              _cursorIndex += 1;
            });
          }
        },
      },
      child: Focus(
        focusNode: _focusNode,
        child: SizeChangedLayoutNotifier(
          child: Column(
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: requestKeyboard,
                child: InputDecorator(
                  decoration: widget.decoration,
                  isFocused: _effectiveFocusNode.hasFocus,
                  isEmpty: _value.text.isEmpty && _chips.isEmpty,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4.0,
                    runSpacing: 4.0,
                    children: chipsChildren,
                  ),
                ),
              ),
              CompositedTransformTarget(
                link: _layerLink,
                child: Container(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
