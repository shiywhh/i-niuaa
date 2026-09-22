// Engine | Flutter 3.x / Dart 3 | lib/ui/widgets.dart
// 通用小部件

import 'package:flutter/material.dart';

/// 描边下拉（plain DropdownButton，兼容性最好）
class LineDropdown<T> extends StatelessWidget {
  final String hint;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  const LineDropdown({
    super.key,
    required this.hint,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black38),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          isDense: true,
          borderRadius: BorderRadius.circular(8),
          hint: Text(hint,
              style:
                  const TextStyle(fontSize: 13, color: Colors.black54)),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
