import 'package:flutter/material.dart' as m;
import 'package:flutter/material.dart' hide Text;

export 'package:flutter/material.dart' hide Text;

/// Screens import this instead of `package:flutter/material.dart`, so every
/// [Text] in the app follows the POS look: uppercase, and one line that
/// shrinks to fit the width instead of being cut off.
///
/// A text that should wrap opts in with `softWrap: true` or `maxLines` > 1;
/// it is still uppercase.
///
/// [data] keeps the original string, so `find.text('Cobrar')` still works in
/// tests. Only the rendered copy is uppercased.
class Text extends m.Text {
  const Text(
    super.data, {
    super.key,
    super.style,
    super.strutStyle,
    super.textAlign,
    super.textDirection,
    super.locale,
    super.softWrap,
    super.overflow,
    super.textScaler,
    super.maxLines,
    super.semanticsLabel,
    super.textWidthBasis,
    super.textHeightBehavior,
    super.selectionColor,
  });

  bool get _wraps => softWrap == true || (maxLines ?? 1) > 1;

  @override
  Widget build(BuildContext context) {
    // Material's build, run in place, so the tree holds this one Text and not
    // a second, uppercased one that finders would also match.
    final text = m.Text(
      data!.toUpperCase(),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: _wraps ? softWrap : false,
      overflow: _wraps ? overflow : TextOverflow.visible,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: semanticsLabel,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    ).build(context);
    if (_wraps) return text;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: switch (textAlign) {
        TextAlign.center => Alignment.center,
        TextAlign.right || TextAlign.end => AlignmentDirectional.centerEnd,
        _ => AlignmentDirectional.centerStart,
      },
      child: text,
    );
  }
}
