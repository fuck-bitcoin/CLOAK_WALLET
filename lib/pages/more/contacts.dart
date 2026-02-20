import 'package:flutter/material.dart';
 
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:go_router/go_router.dart';
import '../../cloak/cloak_types.dart';

import '../../cloak/cloak_wallet_manager.dart';
import '../../cloak/cloak_db.dart';
import '../../accounts.dart';
import '../../appsettings.dart';
import '../../theme/zashi_tokens.dart';
import '../../utils/message_threads.dart';
import '../../generated/intl/messages.dart';
import '../../store2.dart';
import '../scan.dart';
import '../utils.dart';
import '../accounts/send.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Heuristic copied from Messages to recognize address-like strings
bool _isAddressLike(String s) {
  final v = s.trim();
  if (v.isEmpty) return false;
  final lower = v.toLowerCase();
  // Zcash/Ycash address prefixes
  if (v.length >= 14 && (lower.startsWith('u1') || lower.startsWith('uo') || lower.startsWith('zs') || lower.startsWith('t1') || lower.startsWith('t3'))) {
    return true;
  }
  // CLOAK/ZEOS addresses use bech32m encoding (similar to Zcash unified addresses)
  // They are long alphanumeric strings - check for reasonable length
  final only = v.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  if (only.length > 24 && RegExp(r'^[A-Za-z0-9]+').hasMatch(only)) return true;
  return false;
}

// (Removed stray top-level duplicate definition; in-class constant is used.)
class ContactsPage extends StatefulWidget {
  final bool main;
  final bool showAppBar;
  ContactsPage({this.main = false, this.showAppBar = true});

  @override
  State<StatefulWidget> createState() => _ContactsState();
}

class _ContactsState extends State<ContactsPage> {
  bool selected = false;
  final listKey = GlobalKey<ContactListState>();
  S get s => S.of(context);
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';
  

  @override
  void initState() {
    super.initState();
    contacts.fetchContacts();
  }

  @override
  Widget build(BuildContext context) {
    final s = this.s;
    final Widget listOnly = ContactList(
      key: listKey,
      onSelect: (v) => _select(v!),
      onLongSelect: (v) => setState(() => selected = v != null),
      filter: _query,
    );
    final Widget displayTile = _DisplayNameTile(
      onTap: () {
        final r = GoRouter.of(context);
        if (!widget.showAppBar) {
          r.push('/contacts_overlay/display_name');
        } else {
          r.push('/contacts/display_name');
        }
      },
    );
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        displayTile,
        Divider(height: 1, thickness: 1.0),
        Expanded(child: listOnly),
      ],
    );

    if (widget.showAppBar) {
      // Original full-page Contacts layout (unchanged)
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          title: Text(s.contacts),
          actions: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: Row(
                key: ValueKey<bool>(selected),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!selected) IconButton(onPressed: _save, icon: Icon(Icons.save)),
                  if (!selected) IconButton(onPressed: _add, icon: Icon(Icons.add)),
                  if (selected) IconButton(onPressed: _edit, icon: Icon(Icons.edit)),
                  if (selected) IconButton(onPressed: _delete, icon: Icon(Icons.delete)),
                ],
              ),
            ),
          ],
        ),
        body: content,
      );
    } else {
      // Overlay mode: provide a slim header (no AppBar) like Messages compose
      final theme = Theme.of(context);
      final TextStyle? baseTitleStyle = theme.appBarTheme.titleTextStyle ??
          theme.textTheme.titleLarge ??
          theme.textTheme.titleMedium ??
          theme.textTheme.bodyMedium;
      final TextStyle? reducedTitleStyle = (baseTitleStyle?.fontSize != null)
          ? baseTitleStyle!.copyWith(fontSize: baseTitleStyle.fontSize! * 0.75)
          : baseTitleStyle;

      final header = SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => GoRouter.of(context).pop(),
                color: reducedTitleStyle?.color,
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: Text(
                s.contacts.toUpperCase(),
                style: reducedTitleStyle,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                  child: Row(
                    key: ValueKey<bool>(selected),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!selected)
                        IconButton(
                          tooltip: 'Save',
                          onPressed: _save,
                          icon: const Icon(Icons.save),
                          color: reducedTitleStyle?.color,
                        ),
                      if (!selected)
                        IconButton(
                          tooltip: 'Add',
                          onPressed: _add,
                          icon: const Icon(Icons.add),
                          color: reducedTitleStyle?.color,
                        ),
                      if (selected)
                        IconButton(
                          tooltip: 'Edit',
                          onPressed: _edit,
                          icon: const Icon(Icons.edit),
                          color: reducedTitleStyle?.color,
                        ),
                      if (selected)
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: _delete,
                          icon: const Icon(Icons.delete),
                          color: reducedTitleStyle?.color,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      final Color onSurf = theme.colorScheme.onSurface;
      const Color searchFill = Color(0xFF2E2E2E);

      final search = Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: TextField(
          controller: _searchCtl,
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          cursorColor: onSurf,
          decoration: InputDecoration(
            hintText: 'Search',
            prefixIcon:
                Icon(Icons.search, color: onSurf.withOpacity(0.85)),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.close,
                        color: onSurf.withOpacity(0.85)),
                    onPressed: () {
                      _searchCtl.clear();
                      setState(() => _query = '');
                    },
                  ),
            filled: true,
            fillColor: searchFill,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none),
          ),
          style: (theme.textTheme.bodyMedium ?? const TextStyle())
              .copyWith(color: onSurf),
        ),
      );

      return SafeArea(
        child: Material(
          color: theme.scaffoldBackgroundColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              // no divider per request
              search,
              displayTile,
              Divider(height: 1, thickness: 1.0),
              Expanded(child: listOnly),
            ],
          ),
        ),
      );
    }
  }

  _select(int v) {
    final c = contacts.contacts[v];
    if (!widget.main) {
      GoRouter.of(context).pop(c);
    } else {
      // In main/overlay mode, open Contact Info
      final id = c.unpack().id;
      final router = GoRouter.of(context);
      if (!widget.showAppBar) {
        router.push('/contacts_overlay/edit?id=$id');
      } else {
        router.push('/contacts/edit?id=$id');
      }
    }
  }

  _copyToClipboard(int? v) {
    final c = contacts.contacts[v!];
    Clipboard.setData(ClipboardData(text: c.address!));
    showSnackBar(this.s.addressCopiedToClipboard);
  }

  _save() async {
    // CLOAK contacts are stored locally, no on-chain commit needed
    showSnackBar('Contacts saved locally');
  }

  _add() {
    final router = GoRouter.of(context);
    if (!widget.showAppBar) {
      // Stack Add Contact overlay above Contacts overlay without moving it
      router.push('/contacts_overlay/add');
    } else {
      router.push('/contacts/add');
    }
  }

  _edit() {
    final c = listKey.currentState!.selectedContact!;
    final id = c.id;
    final router = GoRouter.of(context);
    if (!widget.showAppBar) {
      router.push('/contacts_overlay/edit?id=$id');
    } else {
      router.push('/contacts/edit?id=$id');
    }
  }

  _delete() async {
    final s = S.of(context);
    final confirmed =
        await showConfirmDialog(context, s.delete, s.confirmDeleteContact);
    if (!confirmed) return;
    final c = listKey.currentState!.selectedContact!;
    // Helpers with simple retries to avoid transient "database is locked"
    Future<void> retry(int attempts, Future<void> Function() op) async {
      int i = 0; int delayMs = 120;
      while (true) {
        try { await op(); return; } catch (_) {
          if (++i >= attempts) rethrow;
          await Future.delayed(Duration(milliseconds: delayMs));
          delayMs = (delayMs * 2).clamp(120, 1000);
        }
      }
    }

    // Property access helpers
    Future<String> getProp(String key) async {
      return await CloakDb.getProperty(key) ?? '';
    }
    Future<void> setProp(String key, String value) async {
      await CloakDb.setProperty(key, value);
    }

    // Mark UA and CID blocked to prevent auto-recreation by message handshake
    final ua = (c.address ?? '').trim();
    if (ua.isNotEmpty) {
      await retry(5, () async { await setProp('contact_block_' + ua, '1'); });
    }
    String cid = '';
    try {
      cid = (await getProp('contact_cid_' + c.id.toString())).trim();
      if (cid.isNotEmpty) {
        await retry(5, () async { await setProp('cid_block_' + cid, '1'); });
      }
    } catch (_) {}
    // Clear linkage so compose treats it as a new conversation next time
    try { await retry(5, () async { await setProp('contact_cid_' + c.id.toString(), ''); }); } catch (_) {}
    // Clear cached titles and preserved invite metadata so old names don't linger
    if (cid.isNotEmpty) {
      try { await retry(5, () async { await setProp('cid_name_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_invite_name_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_inviter_contact_id_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_map_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_accept_done_' + cid, ''); }); } catch (_) {}
    }

    // Delete the contact
    await CloakDb.deleteContact(c.id);
    contacts.fetchContacts();
  }
}

class _DisplayNameTile extends StatelessWidget {
  final VoidCallback? onTap;
  const _DisplayNameTile({this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final TextStyle? baseTitleStyle = (t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge ?? t.textTheme.titleMedium ?? t.textTheme.bodyMedium);
    final Color? headerColor = t.appBarTheme.titleTextStyle?.color ?? baseTitleStyle?.color ?? t.colorScheme.onSurface;
    final TextStyle nameStyle = (baseTitleStyle ?? const TextStyle()).copyWith(color: headerColor);
    final Color baseBg = t.scaffoldBackgroundColor;
    final Color lightGrey = Color.lerp(baseBg, Colors.white, 0.06) ?? baseBg;
    return ListTile(
      title: const Text('Display Name'),
      titleTextStyle: nameStyle,
      onTap: onTap,
      selectedTileColor: lightGrey,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class DisplayNameEditPage extends StatefulWidget {
  final bool showAppBar;
  final bool showPromptOnOpen;
  const DisplayNameEditPage({this.showAppBar = true, this.showPromptOnOpen = false});

  @override
  State<DisplayNameEditPage> createState() => _DisplayNameEditPageState();
}

class _DisplayNameEditPageState extends State<DisplayNameEditPage> {
  final TextEditingController _firstCtl = TextEditingController();
  final TextEditingController _lastCtl = TextEditingController();
  Timer? _debounce;
  bool _editing = true;
  bool _promptShown = false;
  AnimationStatusListener? _routeAnimListener;

  @override
  void initState() {
    super.initState();
    _loadDisplayName();
    if (widget.showPromptOnOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final route = ModalRoute.of(context);
        final anim = route?.animation;
        if (anim != null) {
          _routeAnimListener = (status) {
            if (!_promptShown && status == AnimationStatus.completed) {
              _promptShown = true;
              _showPrompt();
              try { anim.removeStatusListener(_routeAnimListener!); } catch (_) {}
            }
          };
          anim.addStatusListener(_routeAnimListener!);
        } else {
          // Fallback: delay slightly then show
          Future.delayed(const Duration(milliseconds: 600), () {
            if (!_promptShown) { _promptShown = true; _showPrompt(); }
          });
        }
      });
    }
  }

  Future<void> _loadDisplayName() async {
    try {
      if (CloakWalletManager.isCloak(aa.coin)) {
        _firstCtl.text = await CloakDb.getProperty('my_first_name') ?? '';
        _lastCtl.text = await CloakDb.getProperty('my_last_name') ?? '';
      } else {
        _firstCtl.text = '';
        _lastCtl.text = '';
      }
    } catch (_) {}
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _save);
  }

  void _save() async {
    try {
      if (CloakWalletManager.isCloak(aa.coin)) {
        await CloakDb.setProperty('my_first_name', _firstCtl.text.trim());
        await CloakDb.setProperty('my_last_name', _lastCtl.text.trim());
      } else {
        // Only CLOAK is supported
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _firstCtl.dispose();
    _lastCtl.dispose();
    try {
      final anim = ModalRoute.of(context)?.animation;
      if (anim != null && _routeAnimListener != null) {
        anim.removeStatusListener(_routeAnimListener!);
      }
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (widget.showAppBar) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => GoRouter.of(context).pop(),
          ),
          title: const Text('DISPLAY NAME'),
          actions: [
            IconButton(
              onPressed: () {
                _save();
                GoRouter.of(context).pop();
              },
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: _buildFormBody(context, s),
      );
    } else {
      final theme = Theme.of(context);
      final TextStyle? baseTitleStyle = theme.appBarTheme.titleTextStyle ??
          theme.textTheme.titleLarge ??
          theme.textTheme.titleMedium ??
          theme.textTheme.bodyMedium;
      final TextStyle? reducedTitleStyle = (baseTitleStyle?.fontSize != null)
          ? baseTitleStyle!.copyWith(fontSize: baseTitleStyle.fontSize! * 0.75)
          : baseTitleStyle;

      final header = SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => GoRouter.of(context).pop(),
                color: reducedTitleStyle?.color,
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: Text(
                'DISPLAY NAME',
                style: reducedTitleStyle,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: IconButton(
                  tooltip: 'Save',
                  onPressed: () {
                    _save();
                    GoRouter.of(context).pop();
                  },
                  icon: const Icon(Icons.check),
                  color: reducedTitleStyle?.color,
                ),
              ),
            ),
          ],
        ),
      );

      return SafeArea(
        child: Material(
          color: theme.scaffoldBackgroundColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: _buildFormBody(context, s)),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildFormBody(BuildContext context, S s) {
    final theme = Theme.of(context);
    final Color onSurf = theme.colorScheme.onSurface;
    const Color fieldFill = Color(0xFF2E2C2C);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            TextField(
              controller: _firstCtl,
              onChanged: (_) => _scheduleSave(),
              textInputAction: TextInputAction.next,
              cursorColor: onSurf,
              decoration: InputDecoration(
                hintText: 'First Name',
                filled: true,
                fillColor: fieldFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
              style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(color: onSurf),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lastCtl,
              onChanged: (_) => _scheduleSave(),
              textInputAction: TextInputAction.done,
              cursorColor: onSurf,
              decoration: InputDecoration(
                hintText: 'Last Name',
                filled: true,
                fillColor: fieldFill,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
              style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(color: onSurf),
              onEditingComplete: _save,
            ),
          ],
        ),
      ),
    );
  }

  void _showPrompt() {
    try {
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Display Name Needed'),
            content: const Text('Please create a display name.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } catch (_) {}
  }
}

class ContactList extends StatefulWidget {
  final int? initialSelect;
  final void Function(int?)? onSelect;
  final void Function(int?)? onLongSelect;
  final String? filter;
  ContactList(
      {super.key, this.initialSelect, this.onSelect, this.onLongSelect, this.filter});

  @override
  State<StatefulWidget> createState() => ContactListState();
}

class ContactListState extends State<ContactList> {
  late int? selected = widget.initialSelect;
  @override
  void initState() {
    super.initState();
    // Ensure contacts are loaded when this widget mounts (overlay or full page)
    try { contacts.fetchContacts(); } catch (_) {}
  }
  @override
  Widget build(BuildContext context) {
    return Observer(builder: (context) {
      // Show all contacts; automatic address-like entries are prevented upstream.
      final all = contacts.contacts;
      final q = (widget.filter ?? '').trim().toLowerCase();
      final c = q.isEmpty
          ? all
          : all.where((ct) {
              final t = ct.unpack();
              return (t.name ?? '').toLowerCase().contains(q) ||
                  (t.address ?? '').toLowerCase().contains(q);
            }).toList(growable: false);
      if (c.isEmpty) {
        final t = Theme.of(context);
        return Center(
            child: Text(
          S.of(context).contacts,
          style: t.textTheme.bodyMedium?.copyWith(
              color: t.colorScheme.onSurface.withOpacity(0.6)),
        ));
      }
      return ListView.separated(
        itemBuilder: (context, index) => ContactItem(
          c[index].unpack(),
          selected: selected == index,
          onLongPress: null,
          onPress: () => widget.onSelect?.call(index),
        ),
        separatorBuilder: (context, index) => Divider(height: 1, thickness: 0.5),
        itemCount: c.length,
      );
    });
  }

  Contact? get selectedContact => selected?.let((s) => contacts.contacts[s]);
}

class ContactItem extends StatelessWidget {
  final ContactT contact;
  final bool? selected;
  final void Function()? onPress;
  final void Function()? onLongPress;
  ContactItem(this.contact, {this.selected, this.onPress, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final TextStyle? baseTitleStyle = (t.appBarTheme.titleTextStyle ?? t.textTheme.titleLarge ?? t.textTheme.titleMedium ?? t.textTheme.bodyMedium);
    final Color? headerColor = t.appBarTheme.titleTextStyle?.color ?? baseTitleStyle?.color ?? t.colorScheme.onSurface;
    final TextStyle nameStyle = (baseTitleStyle ?? const TextStyle()).copyWith(color: headerColor);
    final Color baseBg = t.scaffoldBackgroundColor;
    final Color lightGrey = Color.lerp(baseBg, Colors.white, 0.06) ?? baseBg;
    return ListTile(
      title: Text(contact.name!, style: nameStyle),
      onTap: onPress,
      onLongPress: onLongPress,
      selected: selected ?? false,
      selectedTileColor: lightGrey,
    );
  }
}

class ContactEditPage extends StatefulWidget {
  final int id;
  final bool showAppBar;
  ContactEditPage(this.id, {this.showAppBar = true});

  @override
  State<StatefulWidget> createState() => _ContactEditState();
}

class _ContactEditState extends State<ContactEditPage> {
  final formKey = GlobalKey<FormBuilderState>();
  final nameController = TextEditingController();
  final addressController = TextEditingController();
  
  
  final firstNameController = TextEditingController();
  final lastNameController = TextEditingController();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    // Load contact from contacts list (already fetched)
    ContactT? c;
    for (final cc in contacts.contacts) {
      final u = cc.unpack();
      if (u.id == widget.id) { c = u; break; }
    }
    nameController.text = c?.name ?? '';
    addressController.text = c?.address ?? '';
    try {
      final name = c?.name ?? '';
      final parts = name.trim().split(RegExp(r"\s+"));
      if (parts.isEmpty) {
        firstNameController.text = '';
        lastNameController.text = '';
      } else if (parts.length == 1) {
        firstNameController.text = parts.first;
        lastNameController.text = '';
      } else {
        firstNameController.text = parts.sublist(0, parts.length - 1).join(' ');
        lastNameController.text = parts.last;
      }
    } catch (_) {}
    
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (widget.showAppBar) {
      return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _backToContacts,
            ),
            title: const Text('CONTACT INFO'),
            actions: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                child: IconButton(
                  key: ValueKey<bool>(_editing),
                  onPressed: _toggleEditOrSave,
                  icon: Icon(_editing ? Icons.check : Icons.edit),
                ),
              ),
            ],
          ),
          body: _buildFormBody(context, s));
    } else {
      final theme = Theme.of(context);
      final TextStyle? baseTitleStyle = theme.appBarTheme.titleTextStyle ??
          theme.textTheme.titleLarge ??
          theme.textTheme.titleMedium ??
          theme.textTheme.bodyMedium;
      final TextStyle? reducedTitleStyle = (baseTitleStyle?.fontSize != null)
          ? baseTitleStyle!.copyWith(fontSize: baseTitleStyle.fontSize! * 0.75)
          : baseTitleStyle;

      final header = SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _backToContacts,
                color: reducedTitleStyle?.color,
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: Text(
                'CONTACT INFO',
                style: reducedTitleStyle,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                  child: IconButton(
                    key: ValueKey<bool>(_editing),
                    tooltip: _editing ? 'Save' : 'Edit',
                    onPressed: _toggleEditOrSave,
                    icon: Icon(_editing ? Icons.check : Icons.edit),
                    color: reducedTitleStyle?.color,
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      return SafeArea(
        child: Material(
          color: theme.scaffoldBackgroundColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: _buildFormBody(context, s)),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildFormBody(BuildContext context, S s) {
    final fieldsReadOnly = !_editing;
    return SingleChildScrollView(
        child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: FormBuilder(
                key: formKey,
                child: Column(children: [
                      const SizedBox(height: 12),
                      // Quick menu copied from Balance page (4 tiles)
                      Observer(builder: (context) {
                        // React to global sequence ticks (e.g., after ACCEPT processing)
                        try { aaSequence.seqno; } catch (_) {}
                        final screenWidth = MediaQuery.of(context).size.width;
                        const horizontalPadding = 32.0; // matches symmetric(horizontal:16)
                        const gap = 6.0;
                        final available = screenWidth - horizontalPadding;
                        final tileSize = ((available - 3 * gap) / 4).clamp(72.0, 96.0).toDouble();
                        // Determine handshake acceptance and persist missing cid using robust union list scan
                        bool isAccepted = false;
                        String cid = '';
                        // CID will be derived from messages scan below
                        cid = '';
                        try {
                          // Build union list (DB + optimistic) to match Messages behavior
                          final List<ZMessage> unionList = () {
                            try {
                              final db = aa.messages.items;
                              final Map<String, ZMessage> byHeader = {};
                              for (final m in db) {
                                try {
                                  final body = (m as dynamic).body as String?;
                                  if (body == null) continue;
                                  final first = body.split('\n').first.trim();
                                  if (!first.startsWith('v1;')) continue;
                                  byHeader[first] = m;
                                } catch (_) {}
                              }
                              final list = db.toList();
                              for (final e in optimisticEchoes) {
                                try {
                                  final key = (e.body).split('\n').first.trim();
                                  if (key.startsWith('v1;') && !list.any((m) => ((m as dynamic).body as String?)?.split('\n').first.trim() == key)) {
                                    list.add(e);
                                  }
                                } catch (_) {}
                              }
                              return list;
                            } catch (_) {
                              return aa.messages.items;
                            }
                          }();
                          // If cid missing, try to derive by matching messages that involve this contact's address
                          if (cid.isEmpty) {
                            final String contactAddr = addressController.text.trim();
                            if (contactAddr.isNotEmpty) {
                              for (final m in unionList.reversed) {
                                try {
                                  final from = (m as dynamic).fromAddress as String? ?? '';
                                  final to = (m as dynamic).recipient as String? ?? '';
                                  if (from != contactAddr && to != contactAddr) continue;
                                  final body = (m as dynamic).body as String? ?? '';
                                  final first = body.split('\n').first.trim();
                                  if (!first.startsWith('v1;')) continue;
                                  String conv = '';
                                  for (final raw in first.split(';')) {
                                    final t = raw.trim();
                                    if (t.isEmpty) continue;
                                    final i = t.indexOf('=');
                                    if (i > 0) {
                                      final k = t.substring(0, i).trim();
                                      final v = t.substring(i + 1).trim();
                                      if (k == 'conversation_id') { conv = v; break; }
                                    }
                                  }
                                  if (conv.isNotEmpty) { cid = conv; break; }
                                } catch (_) {}
                              }
                              if (cid.isNotEmpty) {
                                // Store CID for contact
                                CloakDb.setProperty('contact_cid_' + widget.id.toString(), cid);
                                try { aaSequence.seqno = DateTime.now().microsecondsSinceEpoch; } catch (_) {}
                              }
                            }
                          }
                          if (cid.isNotEmpty) {
                            // Accept status will be checked from message scan below
                            if (!isAccepted) {
                              for (final m in unionList) {
                                try {
                                  final body = (m as dynamic).body as String?;
                                  if (body == null) continue;
                                  final first = body.split('\n').first.trim();
                                  if (!first.startsWith('v1;')) continue;
                                  String type = '';
                                  String conv = '';
                                  for (final raw in first.split(';')) {
                                    final t = raw.trim();
                                    if (t.isEmpty) continue;
                                    final i = t.indexOf('=');
                                    if (i > 0) {
                                      final k = t.substring(0, i).trim();
                                      final v = t.substring(i + 1).trim();
                                      if (k == 'type') type = v; else if (k == 'conversation_id') conv = v;
                                    }
                                  }
                                  if (type == 'accept' && conv == cid) { isAccepted = true; break; }
                                } catch (_) {}
                              }
                              if (isAccepted) {
                                // Persist accept status
                                CloakDb.setProperty('cid_accept_done_' + cid, '1');
                                try { aaSequence.seqno = DateTime.now().microsecondsSinceEpoch; } catch (_) {}
                              }
                            }
                          }
                        } catch (_) {}
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _QuickActionTileSimple(
                              label: 'Chat',
                              iconData: Icons.chat_bubble_outline,
                              onTap: () {
                                try {
                                  final contactId = widget.id;
                                  // Resolve the saved contact to get current name/address
                                  ContactT? t;
                                  try {
                                    for (final c in contacts.contacts) {
                                      final u = c.unpack();
                                      if (u.id == contactId) { t = u; break; }
                                    }
                                  } catch (_) {}
                                  final addr = (t?.address ?? '').trim().isNotEmpty ? (t!.address!.trim()) : addressController.text.trim();
                                  if (addr.isEmpty) {
                                    // No address: reset stack to Balance, then push Messages, then push Compose
                                    GoRouter.of(context).go('/account');
                                    Future.microtask(() {
                                      try { GoRouter.of(context).push('/messages'); } catch (_) {}
                                      Future.microtask(() {
                                        try {
                                          GoRouter.of(context).push('/messages/compose', extra: {'contactId': contactId, 'name': nameController.text.trim()});
                                        } catch (_) {}
                                      });
                                    });
                                    return;
                                  }
                                  // Use unified thread detection
                                  final result = findThreadForContact(contactId, addr, aa.coin);
                                  if (result.exists) {
                                    // Thread exists - navigate to thread view
                                    int? threadIndex = result.index;
                                    if (threadIndex == null || threadIndex < 0) {
                                      // Recalculate index if not found - try multiple strategies
                                      try {
                                        final unionList = buildUnionList();
                                        // Strategy 1: Try with CID if available
                                        if (result.cid != null && result.cid!.isNotEmpty) {
                                          threadIndex = computeThreadIndex(unionList, cid: result.cid, address: addr);
                                        }
                                        // Strategy 2: If still not found, try with address only
                                        if (threadIndex == null || threadIndex < 0) {
                                          threadIndex = computeThreadIndex(unionList, address: addr);
                                        }
                                        // Strategy 3: Last resort - if CID is stored, scan messages directly
                                        if ((threadIndex == null || threadIndex < 0) && result.cid != null && result.cid!.isNotEmpty) {
                                          // Find any message with this CID and calculate index from that
                                          for (int i = 0; i < unionList.length; i++) {
                                            try {
                                              final m = unionList[i];
                                              final body = (m as dynamic).body as String? ?? '';
                                              if (body.isEmpty) continue;
                                              final first = body.split('\n').first.trim();
                                              if (!first.startsWith('v1;')) continue;
                                              // Extract conversation_id from header
                                              String msgCid = '';
                                              for (final raw in first.split(';')) {
                                                final t = raw.trim();
                                                if (t.isEmpty) continue;
                                                final eqIdx = t.indexOf('=');
                                                if (eqIdx > 0) {
                                                  final k = t.substring(0, eqIdx).trim();
                                                  final v = t.substring(eqIdx + 1).trim();
                                                  if (k == 'conversation_id') {
                                                    msgCid = v;
                                                    break;
                                                  }
                                                }
                                              }
                                              if (msgCid == result.cid) {
                                                // Found a message with matching CID, calculate thread index
                                                threadIndex = computeThreadIndex(unionList, cid: result.cid);
                                                break;
                                              }
                                            } catch (_) {}
                                          }
                                        }
                                      } catch (_) {}
                                    }
                                    if (threadIndex != null && threadIndex >= 0) {
                                      // Use CID for stable navigation (index is dynamic and can shift)
                                      if (result.cid != null && result.cid!.isNotEmpty) {
                                        GoRouter.of(context).push('/messages/details?cid=${result.cid}');
                                      } else {
                                        // Fallback to index if CID not available
                                        GoRouter.of(context).push('/messages/details?index=$threadIndex');
                                      }
                                    } else {
                                      // Thread exists but couldn't calculate index - still navigate to compose
                                      // Compose page will detect the thread and show it
                                      GoRouter.of(context).go('/account');
                                      Future.microtask(() {
                                        try { GoRouter.of(context).push('/messages'); } catch (_) {}
                                        Future.microtask(() {
                                          try {
                                            GoRouter.of(context).push('/messages/compose', extra: {'contactId': contactId, 'name': (t?.name ?? nameController.text).trim()});
                                          } catch (_) {}
                                        });
                                      });
                                    }
                                  } else {
                                    // No existing thread: take user to compose for this contact
                                    GoRouter.of(context).go('/account');
                                    Future.microtask(() {
                                      try { GoRouter.of(context).push('/messages'); } catch (_) {}
                                      Future.microtask(() {
                                        try {
                                          GoRouter.of(context).push('/messages/compose', extra: {'contactId': contactId, 'name': (t?.name ?? nameController.text).trim()});
                                        } catch (_) {}
                                      });
                                    });
                                  }
                                } catch (_) {}
                              },
                              tileSize: tileSize,
                            ),
                            const SizedBox(width: gap),
                            _QuickActionTileSimple(
                              label: 'Call',
                              iconData: Icons.phone,
                              onTap: null,
                              disabled: true,
                              tileSize: tileSize,
                            ),
                            const SizedBox(width: gap),
                            _QuickActionTileSimple(
                              label: 'Request',
                              svgString: _ZASHI_REQUEST_GLYPH,
                              assetSize: 33.6,
                              labelOffsetY: 0.0,
                              spacing: 8.0,
                              onTap: isAccepted ? () {
                                // Use contact address (cid_map lookup is async, use address directly)
                                String mapped = '';
                                final String threadAddress = mapped.isNotEmpty ? mapped : addressController.text.trim();
                                // Build union list and compute exact Messages index
                                int threadIndex = -1;
                                try {
                                  final List<ZMessage> unionList = () {
                                    try {
                                      final db = aa.messages.items;
                                      final Map<String, ZMessage> byHeader = {};
                                      for (final m in db) {
                                        try {
                                          final body = (m as dynamic).body as String?;
                                          if (body == null) continue;
                                          final first = body.split('\n').first.trim();
                                          if (!first.startsWith('v1;')) continue;
                                          byHeader[first] = m;
                                        } catch (_) {}
                                      }
                                      final list = db.toList();
                                      for (final e in optimisticEchoes) {
                                        try {
                                          final key = (e.body).split('\n').first.trim();
                                          if (key.startsWith('v1;') && !list.any((m) => ((m as dynamic).body as String?)?.split('\n').first.trim() == key)) {
                                            list.add(e);
                                          }
                                        } catch (_) {}
                                      }
                                      return list;
                                    } catch (_) {
                                      return aa.messages.items;
                                    }
                                  }();
                                  final String? targetCid = cid.isNotEmpty ? cid : null;
                                  threadIndex = computeThreadIndex(unionList, cid: targetCid, address: threadAddress);
                                } catch (_) {}
                                final extras = {
                                  'fromThread': true,
                                  'threadIndex': threadIndex,
                                  'threadCid': cid.isEmpty ? null : cid,
                                  'threadAddress': threadAddress,
                                  'threadDisplayName': nameController.text.trim(),
                                };
                                GoRouter.of(context).push('/account/request?mode=4', extra: extras);
                              } : null,
                              disabled: !isAccepted,
                              tileSize: tileSize,
                            ),
                            const SizedBox(width: gap),
                            _QuickActionTileSimple(
                              label: 'Pay',
                              asset: 'assets/icons/cloak_glyph.svg',
                              onTap: isAccepted ? () {
                                // Use contact address directly
                                String resolved = addressController.text.trim();
                                // Provide thread context back-links if possible
                                int threadIndex = -1;
                                try {
                                  final List<ZMessage> unionList = () {
                                    try {
                                      final db = aa.messages.items;
                                      final Map<String, ZMessage> byHeader = {};
                                      for (final m in db) {
                                        try {
                                          final body = (m as dynamic).body as String?;
                                          if (body == null) continue;
                                          final first = body.split('\n').first.trim();
                                          if (!first.startsWith('v1;')) continue;
                                          byHeader[first] = m;
                                        } catch (_) {}
                                      }
                                      final list = db.toList();
                                      for (final e in optimisticEchoes) {
                                        try {
                                          final key = (e.body).split('\n').first.trim();
                                          if (key.startsWith('v1;') && !list.any((m) => ((m as dynamic).body as String?)?.split('\n').first.trim() == key)) {
                                            list.add(e);
                                          }
                                        } catch (_) {}
                                      }
                                      return list;
                                    } catch (_) {
                                      return aa.messages.items;
                                    }
                                  }();
                                  final String? targetCid = cid.isNotEmpty ? cid : null;
                                  threadIndex = computeThreadIndex(unionList, cid: targetCid, address: resolved);
                                } catch (_) {}
                                final sc = SendContext(
                                  resolved,
                                  7,
                                  Amount(0, false),
                                  MemoData(true, '', ''),
                                  marketPrice.price,
                                  nameController.text.trim(),
                                  true,
                                  threadIndex,
                                  cid.isEmpty ? null : cid,
                                );
                                GoRouter.of(context).push('/account/quick_send', extra: sc);
                              } : null,
                              disabled: !isAccepted,
                              tileSize: tileSize,
                            ),
                          ],
                        );
                      }),
                      const SizedBox(height: 30),
                      Builder(builder: (context) {
                        const addressFillColor = Color(0xFF2E2C2C);
                        return Column(children: [
                          FormBuilderTextField(
                            name: 'first_name',
                            controller: firstNameController,
                            validator: FormBuilderValidators.required(),
                            readOnly: fieldsReadOnly,
                            decoration: InputDecoration(
                              hintText: 'First Name',
                              filled: true,
                              fillColor: addressFillColor,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FormBuilderTextField(
                            name: 'last_name',
                            controller: lastNameController,
                            readOnly: fieldsReadOnly,
                            decoration: InputDecoration(
                              hintText: 'Last Name',
                              filled: true,
                              fillColor: addressFillColor,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ]);
                      }),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Contact Address',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ),
                      // Address styled like memo input (match Add Contact)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _editing ? null : _copyAddressToClipboard,
                        onDoubleTap: _editing ? null : _copyAddressToClipboard,
                        onLongPress: _editing ? null : _copyAddressToClipboard,
                        child: Stack(children: [
                          FormBuilderTextField(
                            name: 'address',
                            controller: addressController,
                            validator: addressValidator,
                            minLines: 5,
                            maxLines: 5,
                            readOnly: fieldsReadOnly,
                            decoration: InputDecoration(
                              hintText: s.address,
                              filled: true,
                              fillColor: const Color(0xFF2E2C2C),
                              contentPadding: const EdgeInsets.fromLTRB(12, 12, 56, 12),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                              enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                              focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                            ),
                          ),
                          Positioned(
                            right: 4,
                            top: 6,
                            child: Builder(builder: (context) {
                              final t = Theme.of(context);
                              const addressFillColor = Color(0xFF2E2C2C);
                              final Color chipBgColor = Color.lerp(addressFillColor, Colors.black, 0.06) ?? addressFillColor;
                              final Color chipBorderColor = (t.extension<ZashiThemeExt>()?.quickBorderColor) ?? t.dividerColor.withOpacity(0.20);
                              return Material(
                                color: chipBgColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  side: BorderSide(color: chipBorderColor),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: _qr,
                                  child: const SizedBox(
                                    width: 36,
                                    height: 36,
                                    child: Center(
                                      child: _AddressQrIcon(),
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ]),
                      ),
                      
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: _delete,
                          child: const Text('Delete Contact'),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFEF5350), // soft red
                            textStyle: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ),
                    ]))));
  }

  _save() async {
    final first = firstNameController.text.trim();
    final last = lastNameController.text.trim();
    final combinedName = (first + ' ' + last).trim();

    if (CloakWalletManager.isCloak(aa.coin)) {
      // CLOAK: Update contact in CloakDb
      await CloakDb.updateContact(widget.id, name: combinedName, address: addressController.text);
    } else {
      // Only CLOAK is supported
    }
    contacts.fetchContacts();

    if (mounted) {
      setState(() => _editing = false);
    } else {
      _editing = false;
    }
  }

  void _backToContacts() {
    final router = GoRouter.of(context);
    try { router.pop(); } catch (_) {}
    if (widget.showAppBar) {
      Future.microtask(() => router.go('/contacts'));
    }
  }

  _qr() async {
    addressController.text =
        await scanQRCode(context, validator: addressValidator);
  }

  

  void _toggleEditOrSave() {
    if (_editing) {
      _save();
    } else {
      setState(() => _editing = true);
    }
  }

  

  void _delete() async {
    final confirmed = await showConfirmDialog(context, 'Delete', 'Delete this contact?');
    if (!confirmed) return;
    final id = widget.id;
    // Helpers with simple retries to avoid transient "database is locked"
    Future<void> retry(int attempts, Future<void> Function() op) async {
      int i = 0; int delayMs = 120;
      while (true) {
        try { await op(); return; } catch (_) {
          if (++i >= attempts) rethrow;
          await Future.delayed(Duration(milliseconds: delayMs));
          delayMs = (delayMs * 2).clamp(120, 1000);
        }
      }
    }

    // Property access helpers
    Future<String> getProp(String key) async {
      return await CloakDb.getProperty(key) ?? '';
    }
    Future<void> setProp(String key, String value) async {
      await CloakDb.setProperty(key, value);
    }

    // Mark UA and CID blocked to prevent auto-recreation by message handshake
    final ua = addressController.text.trim();
    if (ua.isNotEmpty) {
      await retry(5, () async { await setProp('contact_block_' + ua, '1'); });
    }
    String cid = '';
    try {
      cid = (await getProp('contact_cid_' + id.toString())).trim();
      if (cid.isNotEmpty) {
        await retry(5, () async { await setProp('cid_block_' + cid, '1'); });
      }
    } catch (_) {}
    // Clear linkage so compose treats it as a new conversation next time
    try { await retry(5, () async { await setProp('contact_cid_' + id.toString(), ''); }); } catch (_) {}
    // Clear cached titles and preserved invite metadata so old names don't linger
    if (cid.isNotEmpty) {
      try { await retry(5, () async { await setProp('cid_name_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_invite_name_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_inviter_contact_id_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_map_' + cid, ''); }); } catch (_) {}
      try { await retry(5, () async { await setProp('cid_accept_done_' + cid, ''); }); } catch (_) {}
    }

    // Delete the contact
    await CloakDb.deleteContact(id);
    contacts.fetchContacts();
    _backToContacts();
  }

  void _copyAddressToClipboard() {
    final addr = addressController.text.trim();
    if (addr.isEmpty) return;
    Clipboard.setData(ClipboardData(text: addr));
    showSnackBar('Address copied to clipboard');
  }
}

class _QuickActionTileSimple extends StatelessWidget {
  final String label;
  final String? asset;
  final String? svgString;
  final IconData? iconData;
  final void Function()? onTap;
  final void Function()? onLongPress;
  final double tileSize;
  final bool disabled;
  final double? assetSize;
  final double labelOffsetY;
  final double spacing;
  const _QuickActionTileSimple({required this.label, this.asset, this.svgString, this.iconData, required this.onTap, this.onLongPress, required this.tileSize, this.disabled = false, this.assetSize, this.labelOffsetY = 0.0, this.spacing = 8.0});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final zashi = t.extension<ZashiThemeExt>();
    final gradTop = zashi?.quickGradTop ?? t.colorScheme.surfaceVariant;
    final gradBottom = zashi?.quickGradBottom ?? t.colorScheme.surface;
    final borderColor = zashi?.quickBorderColor ?? t.dividerColor;
    final textStyle = (t.textTheme.bodySmall ?? const TextStyle()).copyWith(fontWeight: FontWeight.w700);
    final iconColor = disabled ? t.disabledColor : Colors.white;
    final gradTopEff = disabled ? Color.lerp(gradTop, Colors.black, 0.08)! : gradTop;
    final gradBottomEff = disabled ? Color.lerp(gradBottom, Colors.black, 0.08)! : gradBottom;
    final borderColorEff = disabled ? borderColor.withOpacity(0.35) : borderColor;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        width: tileSize,
        height: tileSize,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(colors: [gradTopEff, gradBottomEff], begin: Alignment.topCenter, end: Alignment.bottomCenter),
          border: Border.all(color: borderColorEff),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabled ? null : onTap,
          onLongPress: disabled ? null : onLongPress,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (iconData != null)
                Icon(iconData, size: 24, color: iconColor)
              else if (svgString != null)
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Align(
                    alignment: Alignment.center,
                    child: Transform.translate(
                      offset: const Offset(10.0, 13.0),
                      child: Transform.scale(
                        scale: 2.0,
                        child: SvgPicture.string(
                          svgString!,
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                        ),
                      ),
                    ),
                  ),
                )
              else if (asset != null)
                SvgPicture.asset(
                  asset!,
                  width: (assetSize ?? 24),
                  height: (assetSize ?? 24),
                  colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
                ),
              SizedBox(height: spacing),
              Transform.translate(
                offset: Offset(0, labelOffsetY),
                child: Text(label, style: textStyle.copyWith(color: disabled ? t.disabledColor : null)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ContactAddPage extends StatefulWidget {
  final String? initialAddress;
  final bool showAppBar;
  ContactAddPage({this.initialAddress, this.showAppBar = true});
  @override
  State<StatefulWidget> createState() => _ContactAddState();
}

class _ContactAddState extends State<ContactAddPage> {
  final formKey = GlobalKey<FormBuilderState>();
  final nameController = TextEditingController();
  final firstNameController = TextEditingController();
  final lastNameController = TextEditingController();
  final addressController = TextEditingController();
  // Removed reply-to controller; reply-to UA is generated lazily by chat flows

  @override
  void initState() {
    super.initState();
    final init = widget.initialAddress;
    if (init != null && init.isNotEmpty) {
      addressController.text = init;
    }
    // No pre-generation of reply-to UA for Add Contact; generated lazily in chat flows when needed
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (widget.showAppBar) {
      return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _backToContacts,
            ),
            title: Text(s.addContact),
            actions: const [],
          ),
          body: _buildFormBody(context, s));
    } else {
      final theme = Theme.of(context);
      final TextStyle? baseTitleStyle = theme.appBarTheme.titleTextStyle ??
          theme.textTheme.titleLarge ??
          theme.textTheme.titleMedium ??
          theme.textTheme.bodyMedium;
      final TextStyle? reducedTitleStyle = (baseTitleStyle?.fontSize != null)
          ? baseTitleStyle!.copyWith(fontSize: baseTitleStyle.fontSize! * 0.75)
          : baseTitleStyle;

      final header = SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: _backToContacts,
                color: reducedTitleStyle?.color,
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: Text(
                s.addContact.toUpperCase(),
                style: reducedTitleStyle,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox.shrink(),
          ],
        ),
      );

      return SafeArea(
        child: Material(
          color: theme.scaffoldBackgroundColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: _buildFormBody(context, s)),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildFormBody(BuildContext context, S s) {
    const String zashiQrGlyph =
        '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
        '  <g transform="translate(0.5,0.5)">\n'
        '    <path d="M13.833 18H18V22.167M10.508 18H10.5M14.675 22.167H14.667M18.008 25.5H18M25.508 18H25.5M10.5 22.167H11.75M20.917 18H22.583M10.5 25.5H14.667M18 9.667V14.667M22.667 25.5H24.167C24.633 25.5 24.867 25.5 25.045 25.409C25.202 25.329 25.329 25.202 25.409 25.045C25.5 24.867 25.5 24.633 25.5 24.167V22.667C25.5 22.2 25.5 21.967 25.409 21.788C25.329 21.632 25.202 21.504 25.045 21.424C24.867 21.333 24.633 21.333 24.167 21.333H22.667C22.2 21.333 21.967 21.333 21.788 21.424C21.632 21.504 21.504 21.632 21.424 21.788C21.333 21.967 21.333 22.2 21.333 22.667V24.167C21.333 24.633 21.333 24.867 21.424 25.045C21.504 25.202 21.632 25.329 21.788 25.409C21.967 25.5 22.2 25.5 22.667 25.5ZM22.667 14.667H24.167C24.633 14.667 24.867 14.667 25.045 14.576C25.202 14.496 25.329 14.368 25.409 14.212C25.5 14.033 25.5 13.8 25.5 13.333V11.833C25.5 11.367 25.5 11.133 25.409 10.955C25.329 10.798 25.202 10.671 25.045 10.591C24.867 10.5 24.633 10.5 24.167 10.5H22.667C22.2 10.5 21.967 10.5 21.788 10.591C21.632 10.671 21.504 10.798 21.424 10.955C21.333 11.133 21.333 11.367 21.333 11.833V13.333C21.333 13.8 21.333 14.033 21.424 14.212C21.504 14.368 21.632 14.496 21.788 14.576C21.967 14.667 22.2 14.667 22.667 14.667ZM11.833 14.667H13.333C13.8 14.667 14.033 14.667 14.212 14.576C14.368 14.496 14.496 14.368 14.576 14.212C14.667 14.033 14.667 13.8 14.667 13.333V11.833C14.667 11.367 14.667 11.133 14.576 10.955C14.496 10.798 14.368 10.671 14.212 10.591C14.033 10.5 13.8 10.5 13.333 10.5H11.833C11.367 10.5 11.133 10.5 10.955 10.591C10.798 10.671 10.671 10.798 10.591 10.955C10.5 11.133 10.5 11.367 10.5 11.833V13.333C10.5 13.8 10.5 14.033 10.591 14.212C10.671 14.368 10.798 14.496 10.955 14.576C11.133 14.667 11.367 14.667 11.833 14.667Z" stroke="#231F20" stroke-width="1.4" stroke-linecap="square" stroke-linejoin="miter" fill="none"/>\n'
        '  </g>\n'
        '</svg>';
    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: FormBuilder(
          key: formKey,
          child: Column(
            children: [
              const SizedBox(height: 12),
              Builder(builder: (context) {
                const addressFillColor = Color(0xFF2E2C2C);
                return Column(children: [
                  FormBuilderTextField(
                    name: 'first_name',
                    controller: firstNameController,
                    validator: FormBuilderValidators.required(),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'First Name',
                      filled: true,
                      fillColor: addressFillColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FormBuilderTextField(
                    name: 'last_name',
                    controller: lastNameController,
                    decoration: InputDecoration(
                      hintText: 'Last Name',
                      filled: true,
                      fillColor: addressFillColor,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ]);
              }),
              const SizedBox(height: 12),
              // Address styled like memo input
              Stack(children: [
                FormBuilderTextField(
                  name: 'address',
                  controller: addressController,
                  validator: addressValidator,
                  onChanged: (_) => setState(() {}),
                  minLines: 5,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: s.address,
                    filled: true,
                    fillColor: const Color(0xFF2E2C2C),
                    contentPadding: const EdgeInsets.fromLTRB(12, 12, 56, 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                  ),
                ),
                Positioned(
                  right: 4,
                  top: 6,
                  child: Builder(builder: (context) {
                    final t = Theme.of(context);
                    const addressFillColor = Color(0xFF2E2C2C);
                    final Color chipBgColor = Color.lerp(addressFillColor, Colors.black, 0.06) ?? addressFillColor;
                    final Color chipBorderColor = (t.extension<ZashiThemeExt>()?.quickBorderColor) ?? t.dividerColor.withOpacity(0.20);
                    return Material(
                      color: chipBgColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: chipBorderColor),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: _qr,
                        child: const SizedBox(
                          width: 36,
                          height: 36,
                          child: Center(
                            child: _AddressQrIcon(),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ]),
              const SizedBox(height: 8),
              // Reply-to address field removed; chat flows lazily generate reply-to when needed
              const SizedBox(height: 12),
              Builder(builder: (context) {
                final bool canSave = firstNameController.text.trim().isNotEmpty &&
                    addressValidator(addressController.text) == null;
                final t = Theme.of(context);
                final zashi = t.extension<ZashiThemeExt>();
                final Color balanceCursorColor = zashi?.balanceAmountColor ?? t.colorScheme.primary;
                final String? balanceFontFamily = t.textTheme.displaySmall?.fontFamily;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: !canSave
                      ? const SizedBox.shrink(key: ValueKey('no-save'))
                      : Align(
                          key: const ValueKey('save-btn'),
                          alignment: Alignment.center,
                          child: FractionallySizedBox(
                            widthFactor: 0.96,
                            child: SizedBox(
                              height: 48,
                              child: Material(
                                color: balanceCursorColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: add,
                                  child: Center(
                                    child: Text(
                                      'Save',
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
                          ),
                        ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  _qr() async {
    addressController.text =
        await scanQRCode(context, validator: addressValidator);
  }

  add() async {
    final form = formKey.currentState!;
    if (form.validate()) {
      final first = firstNameController.text.trim();
      final last = lastNameController.text.trim();
      final combinedName = (first + ' ' + last).trim();

      if (CloakWalletManager.isCloak(aa.coin)) {
        // CLOAK: Add contact to CloakDb
        await CloakDb.addContact(name: combinedName, address: addressController.text);
      } else {
        // Only CLOAK is supported
      }
      contacts.fetchContacts();
      try {
        final items = contacts.contacts;
        final matches = items.where((cc) {
          final t = cc.unpack();
          return (t.name ?? '') == combinedName &&
              (t.address ?? '') == addressController.text;
        }).toList(growable: false);
        // No longer storing reply-to UA at add time; it will be set lazily when needed by chat
        if (matches.isNotEmpty) {
          // Keep block to preserve structure; intentionally no-op
        }
      } catch (_) {}
      _backToContacts();
    }
  }

  void _backToContacts() {
    final router = GoRouter.of(context);
    try { router.pop(); } catch (_) {}
    if (widget.showAppBar) {
      Future.microtask(() => router.go('/contacts'));
    }
  }

  // Reply-to generation helpers removed; handled by chat invite/accept flows
}

class _AddressQrIcon extends StatelessWidget {
  const _AddressQrIcon();
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    const String zashiQrGlyph =
        '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
        '  <g transform="translate(0.5,0.5)">\n'
        '    <path d="M13.833 18H18V22.167M10.508 18H10.5M14.675 22.167H14.667M18.008 25.5H18M25.508 18H25.5M10.5 22.167H11.75M20.917 18H22.583M10.5 25.5H14.667M18 9.667V14.667M22.667 25.5H24.167C24.633 25.5 24.867 25.5 25.045 25.409C25.202 25.329 25.329 25.202 25.409 25.045C25.5 24.867 25.5 24.633 25.5 24.167V22.667C25.5 22.2 25.5 21.967 25.409 21.788C25.329 21.632 25.202 21.504 25.045 21.424C24.867 21.333 24.633 21.333 24.167 21.333H22.667C22.2 21.333 21.967 21.333 21.788 21.424C21.632 21.504 21.504 21.632 21.424 21.788C21.333 21.967 21.333 22.2 21.333 22.667V24.167C21.333 24.633 21.333 24.867 21.424 25.045C21.504 25.202 21.632 25.329 21.788 25.409C21.967 25.5 22.2 25.5 22.667 25.5ZM22.667 14.667H24.167C24.633 14.667 24.867 14.667 25.045 14.576C25.202 14.496 25.329 14.368 25.409 14.212C25.5 14.033 25.5 13.8 25.5 13.333V11.833C25.5 11.367 25.5 11.133 25.409 10.955C25.329 10.798 25.202 10.671 25.045 10.591C24.867 10.5 24.633 10.5 24.167 10.5H22.667C22.2 10.5 21.967 10.5 21.788 10.591C21.632 10.671 21.504 10.798 21.424 10.955C21.333 11.133 21.333 11.367 21.333 11.833V13.333C21.333 13.8 21.333 14.033 21.424 14.212C21.504 14.368 21.632 14.496 21.788 14.576C21.967 14.667 22.2 14.667 22.667 14.667ZM11.833 14.667H13.333C13.8 14.667 14.033 14.667 14.212 14.576C14.368 14.496 14.496 14.368 14.576 14.212C14.667 14.033 14.667 13.8 14.667 13.333V11.833C14.667 11.367 14.667 11.133 14.576 10.955C14.496 10.798 14.368 10.671 14.212 10.591C14.033 10.5 13.8 10.5 13.333 10.5H11.833C11.367 10.5 11.133 10.5 10.955 10.591C10.798 10.671 10.671 10.798 10.591 10.955C10.5 11.133 10.5 11.367 10.5 11.833V13.333C10.5 13.8 10.5 14.033 10.591 14.212C10.671 14.368 10.798 14.496 10.955 14.576C11.133 14.667 11.367 14.667 11.833 14.667Z" stroke="#231F20" stroke-width="1.4" stroke-linecap="square" stroke-linejoin="miter" fill="none"/>\n'
        '  </g>\n'
        '</svg>';
    return SvgPicture.string(
      zashiQrGlyph,
      width: 32,
      height: 32,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

// Exact Zashi REQUEST glyph (sourced from Receive page)
const String _ZASHI_REQUEST_GLYPH =
    '<svg width="36" height="36" viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">\n'
    '  <g transform="translate(1.8,1.8)">\n'
    '    <path d="M9.186 5.568C8.805 5.84 8.338 6 7.833 6C6.545 6 5.5 4.955 5.5 3.666C5.5 2.378 6.545 1.333 7.833 1.333C8.669 1.333 9.401 1.772 9.814 2.432M4.167 13.391H5.907C6.134 13.391 6.359 13.418 6.579 13.472L8.418 13.919C8.817 14.016 9.233 14.026 9.636 13.947L11.669 13.552C12.206 13.447 12.7 13.19 13.087 12.813L14.525 11.414C14.936 11.015 14.936 10.368 14.525 9.968C14.155 9.609 13.57 9.568 13.151 9.873L11.475 11.096C11.235 11.272 10.943 11.366 10.642 11.366H9.024L10.054 11.366C10.635 11.366 11.105 10.909 11.105 10.344V10.139C11.105 9.67 10.777 9.261 10.309 9.148L8.719 8.761C8.46 8.698 8.195 8.666 7.929 8.666C7.286 8.666 6.121 9.199 6.121 9.199L4.167 10.016M13.5 4.333C13.5 5.622 12.455 6.666 11.167 6.666C9.878 6.666 8.833 5.622 8.833 4.333C8.833 3.044 9.878 2 11.167 2C12.455 2 13.5 3.044 13.5 4.333ZM1.5 9.733L1.5 13.6C1.5 13.973 1.5 14.16 1.573 14.302C1.637 14.428 1.739 14.53 1.864 14.594C2.007 14.666 2.193 14.666 2.567 14.666H3.1C3.473 14.666 3.66 14.666 3.803 14.594C3.928 14.53 4.03 14.428 4.094 14.302C4.167 14.16 4.167 13.973 4.167 13.6V9.733C4.167 9.36 4.167 9.173 4.094 9.03C4.03 8.905 3.928 8.803 3.803 8.739C3.66 8.666 3.473 8.666 3.1 8.666L2.567 8.666C2.193 8.666 2.007 8.666 1.864 8.739C1.739 8.803 1.637 8.905 1.573 9.03C1.5 9.173 1.5 9.36 1.5 9.733Z" stroke="#231F20" stroke-width="1.33333" stroke-linecap="round" stroke-linejoin="round" fill="none"/>\n'
    '  </g>\n'
    '</svg>';
