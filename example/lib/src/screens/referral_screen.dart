import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';

import '../demo_state.dart';
import '../widgets/async_button.dart';
import '../widgets/created_link.dart';
import '../widgets/feedback.dart';
import '../widgets/info_section.dart';

/// `/referral`: invite friends with a link that carries your user ID, and
/// see who invited you when an invite link opened the app.
class ReferralScreen extends StatefulWidget {
  const ReferralScreen({super.key, required this.demo, this.link});

  final DemoState demo;

  /// The invite link that opened this screen, if any.
  final LinkEvent? link;

  @override
  State<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends State<ReferralScreen> {
  late final TextEditingController _userId = TextEditingController(
    text: widget.demo.userId ?? 'demo_user_42',
  );
  String? _inviteUrl;

  @override
  void dispose() {
    _userId.dispose();
    super.dispose();
  }

  Future<String> _createInvite() async {
    final url = await widget.demo.createReferralLink(_userId.text.trim());
    if (mounted) setState(() => _inviteUrl = url);
    return 'Invite link created';
  }

  @override
  Widget build(BuildContext context) {
    final demo = widget.demo;
    // Link data is untrusted: shown as text, never used to grant anything
    // without checking it on your server.
    final referrer = widget.link?.data['referrer_user_id'];
    final inviteUrl = _inviteUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Invite a friend')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (widget.link != null) ...<Widget>[
            InfoSection(
              title: 'You were invited',
              children: <Widget>[
                InfoRow(
                  label: 'Invited by (referrer_user_id)',
                  value: referrer is String
                      ? referrer
                      : 'Not in this link: it was created without a user '
                            'ID, or while tracking was off.',
                ),
                const SectionNote(
                  'Rewards are up to your app; confirm the referrer on your '
                  'server. The Debug screen shows the whole link.',
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          InfoSection(
            title: 'Invite friends',
            children: <Widget>[
              const SizedBox(height: 4),
              TextField(
                controller: _userId,
                decoration: const InputDecoration(
                  labelText: 'Your user ID',
                  helperText:
                      'Your internal ID, never an email address or '
                      'phone number.',
                  helperMaxLines: 2,
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: AsyncButton(
                  label: 'Create invite link',
                  icon: Icons.add_link,
                  kind: AsyncButtonKind.filled,
                  onPressed: demo.isConfigured
                      ? () => runWithFeedback(context, _createInvite)
                      : null,
                ),
              ),
              if (inviteUrl != null) CreatedLink(url: inviteUrl),
              SectionNote(
                demo.isConfigured
                    ? 'The SDK adds your user ID to the link data as '
                          'referrer_user_id, unless tracking is off. A friend '
                          'who opens the link lands on this screen.'
                    : 'Start the SDK with your key (see the home screen) to '
                          'create links.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
