import 'package:flutter/material.dart';

import '../services/schedulers/scheduler_type.dart';

class SchedulingAlgorithmSelector
    extends StatelessWidget {
  final SchedulerType selected;
  final ValueChanged<SchedulerType> onChanged;

  const SchedulingAlgorithmSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  Future<void> _showSelector(
    BuildContext context,
  ) async {
    final result =
        await showDialog<SchedulerType>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text(
            'Select Scheduling Algorithm',
          ),
          children: SchedulerType.values
              .where((t) => !t.isBaseline)
              .map(
                (type) => SimpleDialogOption(
                  onPressed: () {
                    Navigator.of(context)
                        .pop(type);
                  },
                  child: Row(
                    children: [
                      Icon(
                        type == selected
                            ? Icons
                                .radio_button_checked
                            : Icons
                                .radio_button_unchecked,
                        color: type == selected
                            ? Colors.black
                            : Colors.grey,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment
                                  .start,
                          children: [
                            Text(
                              type.displayName,
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight.w600,
                              ),
                            ),
                            const SizedBox(
                              height: 3,
                            ),
                            Text(
                              type.description,
                              style:
                                  TextStyle(
                                fontSize: 12,
                                color: Colors
                                    .grey
                                    .shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        );
      },
    );

    if (result != null && result != selected) {
      onChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => _showSelector(context),
      icon: const Icon(
        Icons.alt_route,
        size: 20,
      ),
      label: Text(
        'Algorithm: ${selected.displayName}',
      ),
      style: OutlinedButton.styleFrom(
        padding:
            const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        side: BorderSide(
          color: Colors.grey.shade300,
        ),
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.circular(8),
        ),
      ),
    );
  }
}