import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:warp_api/data_fb_generated.dart';
import 'package:warp_api/warp_api.dart';

import '../../accounts.dart';
import '../../coin/coins.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../../theme/zashi_tokens.dart';
import '../utils.dart';

class RescanPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _RescanState();
}

class _RescanState extends State<RescanPage> with WithLoadingAnimation {
  late final s = S.of(context);
  final formKey = GlobalKey<FormBuilderState>();
  final minDate = activationDate;
  DateTime maxDate = DateTime.now();
  DateTime? _selectedDate;
  final _heightController = TextEditingController();
  bool _useDate = true; // Toggle between date picker and manual height

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;

    final titleStyle = (t.textTheme.titleMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor,
      fontFamily: balanceFontFamily,
      fontWeight: FontWeight.w500,
    );
    final bodyStyle = (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: balanceTextColor.withOpacity(0.8),
      fontFamily: balanceFontFamily,
    );
    final radius = BorderRadius.circular(14);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(s.rescan),
        actions: [
          IconButton(onPressed: _rescan, icon: Icon(Icons.check)),
        ],
      ),
      body: wrapWithLoading(
        SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: FormBuilder(
              key: formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Choose start date for rescan', style: titleStyle),
                  Gap(8),
                  Text(
                    'Select when your wallet was created to speed up syncing.',
                    style: bodyStyle,
                  ),
                  Gap(24),

                  // Toggle between Date and Height
                  Container(
                    decoration: BoxDecoration(
                      color: balanceTextColor.withOpacity(0.1),
                      borderRadius: radius,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildToggleButton(
                            label: 'Select Date',
                            isSelected: _useDate,
                            onTap: () => setState(() => _useDate = true),
                            balanceTextColor: balanceTextColor,
                            radius: radius,
                          ),
                        ),
                        Expanded(
                          child: _buildToggleButton(
                            label: 'Enter Height',
                            isSelected: !_useDate,
                            onTap: () => setState(() => _useDate = false),
                            balanceTextColor: balanceTextColor,
                            radius: radius,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Gap(20),

                  if (_useDate) ...[
                    // Styled date picker button
                    _buildDatePickerField(
                      context: context,
                      balanceTextColor: balanceTextColor,
                      radius: radius,
                    ),
                  ] else ...[
                    // Height input with info button
                    _buildHeightField(
                      context: context,
                      balanceTextColor: balanceTextColor,
                    ),
                  ],

                  Gap(24),
                  // Warning box with consistent styling
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: radius,
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.red, size: 24),
                        Gap(12),
                        Expanded(
                          child: Text(
                            s.rescanWarning,
                            style: bodyStyle.copyWith(color: Colors.red.shade300),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggleButton({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required Color balanceTextColor,
    required BorderRadius radius,
  }) {
    return Material(
      color: isSelected ? balanceTextColor : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Theme.of(context).colorScheme.background : balanceTextColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDatePickerField({
    required BuildContext context,
    required Color balanceTextColor,
    required BorderRadius radius,
  }) {
    final dateFormat = DateFormat('MMMM d, yyyy');
    final displayDate = _selectedDate ?? minDate;

    return FormBuilderField<DateTime>(
      name: 'date',
      initialValue: _selectedDate,
      builder: (field) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showStyledDatePicker(context, field),
          borderRadius: radius,
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: balanceTextColor.withOpacity(0.3)),
              borderRadius: radius,
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today, color: balanceTextColor, size: 20),
                Gap(12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wallet Birthday Date',
                        style: TextStyle(
                          color: balanceTextColor.withOpacity(0.6),
                          fontSize: 12,
                        ),
                      ),
                      Gap(4),
                      Text(
                        dateFormat.format(displayDate),
                        style: TextStyle(
                          color: balanceTextColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_drop_down, color: balanceTextColor),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showStyledDatePicker(BuildContext context, FormFieldState<DateTime> field) async {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);

    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? minDate,
      firstDate: minDate,
      lastDate: maxDate,
      builder: (context, child) {
        return Theme(
          data: t.copyWith(
            colorScheme: t.colorScheme.copyWith(
              primary: balanceTextColor,
              onPrimary: t.colorScheme.background,
              surface: t.colorScheme.surface,
              onSurface: balanceTextColor,
            ),
            dialogBackgroundColor: t.colorScheme.background,
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() => _selectedDate = picked);
      field.didChange(picked);
    }
  }

  Widget _buildHeightField({
    required BuildContext context,
    required Color balanceTextColor,
  }) {
    return FormBuilderTextField(
      name: 'height',
      controller: _heightController,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Block Height (Optional)',
        hintText: 'e.g., 1500000',
        suffixIcon: IconButton(
          icon: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: balanceTextColor.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              'i',
              style: TextStyle(
                color: balanceTextColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          onPressed: () => _showHeightInfoModal(context),
        ),
      ),
      validator: (v) => (v?.isEmpty != false
          ? null
          : FormBuilderValidators.integer()(v)),
    );
  }

  void _showHeightInfoModal(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final balanceTextColor = zashi?.balanceAmountColor ?? const Color(0xFFBDBDBD);
    final balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
    final radius = BorderRadius.circular(14);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: radius),
        title: Text(
          'What is Block Height?',
          style: (t.textTheme.titleLarge ?? const TextStyle()).copyWith(
            color: balanceTextColor,
            fontFamily: balanceFontFamily,
            fontWeight: FontWeight.w500,
          ),
        ),
        content: Text(
          'Block height is a number that represents a specific point in the Zcash blockchain history.\n\n'
          'Each block is created roughly every 75 seconds. If you know the exact block height when your wallet was created, '
          'entering it here will make syncing faster.\n\n'
          'If you\'re unsure, use the date picker instead - it\'s easier and works just as well!',
          style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
            color: balanceTextColor.withOpacity(0.9),
            fontFamily: balanceFontFamily,
            height: 1.5,
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: Material(
              color: balanceTextColor,
              shape: RoundedRectangleBorder(borderRadius: radius),
              child: InkWell(
                borderRadius: radius,
                onTap: () => Navigator.of(context).pop(),
                child: Center(
                  child: Text(
                    'Got it',
                    style: (t.textTheme.titleSmall ?? const TextStyle()).copyWith(
                      fontFamily: balanceFontFamily,
                      fontWeight: FontWeight.w600,
                      color: t.colorScheme.background,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  _rescan() async {
    final form = formKey.currentState!;
    if (form.validate()) {
      form.save();
      String? h = _heightController.text.trim();
      DateTime d = _selectedDate ?? minDate;
      load(() async {
        final height = (h?.isNotEmpty == true && !_useDate)
            ? int.parse(h!)
            : await WarpApi.getBlockHeightByTime(aa.coin, d);
        final confirmed = await showConfirmDialog(
            context, s.rescan, s.confirmRescanFrom(height));
        if (!confirmed) return;
        aa.reset(height);
        Future(() => syncStatus2.rescan(height));
        GoRouter.of(context).pop();
      });
    }
  }
}

class RewindPage extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _RewindState();
}

class _RewindState extends State<RewindPage> {
  late final s = S.of(context);
  int? selected;
  bool calendar = true;
  DateTime? dateSelected;
  final List<Checkpoint> checkpoints = WarpApi.getCheckpoints(aa.coin);
  // Keep dates aligned with checkpoints order to allow using the same index
  // across calendar and list views.
  late final List<DateTime> checkpointDates = checkpoints
      .map((cp) => _toDate(cp.timestamp, dateOnly: true))
      .toList();

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    DateTime _initialSelectableDate() {
      final dates = checkpointDates
          .where((d) => !d.isAfter(today))
          .toList();
      dates.sort();
      return dates.isNotEmpty ? dates.last : today;
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Text(s.rewind),
        actions: [
        calendar
            ? IconButton(
                onPressed: () => setState(() => calendar = false),
                icon: Icon(Icons.list))
            : IconButton(
                onPressed: () => setState(() => calendar = true),
                icon: Icon(Icons.event)),
        if (selected != null)
          IconButton(onPressed: rewind, icon: Icon(Icons.check)),
      ]),
      body: calendar
          ? CalendarDatePicker(
              initialDate: _initialSelectableDate(),
              firstDate: activationDate,
              lastDate: today,
              onDateChanged: _selectDate,
              selectableDayPredicate: (dt) => checkpointDates.contains(dt),
            )
          : ListView.separated(
              itemBuilder: (context, index) {
                final cp = checkpoints[index];
                final time = noteDateFormat.format(_toDate(cp.timestamp));
                return ListTile(
                  selected: index == selected,
                  title: Text(time),
                  trailing: Text(cp.height.toString()),
                  onTap: () => setState(
                      () => selected = index != selected ? index : null),
                );
              },
              separatorBuilder: (context, index) => Divider(),
              itemCount: checkpoints.length),
    );
  }

  _selectDate(DateTime dt) {
    // Align selected index with the checkpoints list. Use the first checkpoint
    // matching the chosen date; if none, clear selection.
    final idx = checkpoints.indexWhere(
        (cp) => _toDate(cp.timestamp, dateOnly: true) == dt);
    selected = idx >= 0 ? idx : null;
    dateSelected = dt;
    setState(() {});
  }

  rewind() async {
    final height = checkpoints[selected!].height;
    final confirmed =
        await showConfirmDialog(context, s.rewind, s.confirmRewind(height));
    if (!confirmed) return;
    WarpApi.rewindTo(aa.coin, height);
    Future(() async {
      syncStatus2.sync(true);
    });
    GoRouter.of(context).pop();
  }

  DateTime _toDate(int ts, {bool dateOnly = false}) {
    var dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    if (dateOnly) dt = DateTime(dt.year, dt.month, dt.day);
    return dt;
  }
}
