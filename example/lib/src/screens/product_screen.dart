import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/material.dart';

import '../demo_state.dart';
import '../widgets/async_button.dart';
import '../widgets/created_link.dart';
import '../widgets/feedback.dart';
import '../widgets/info_section.dart';
import '../widgets/link_details.dart';

/// `/product/:id`: what a link with deep-link path `/product/123` opens.
class ProductScreen extends StatefulWidget {
  const ProductScreen({
    super.key,
    required this.demo,
    required this.productId,
    this.link,
  });

  final DemoState demo;
  final String productId;

  /// The link that opened this screen, or `null` when the app navigated
  /// here itself.
  final LinkEvent? link;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  String? _shareUrl;

  Future<String> _createShareLink() async {
    final url = await widget.demo.createProductLink(widget.productId);
    if (mounted) setState(() => _shareUrl = url);
    return 'Share link created';
  }

  @override
  Widget build(BuildContext context) {
    final demo = widget.demo;
    final link = widget.link;
    final shareUrl = _shareUrl;
    final canCallSdk = demo.isConfigured;
    return Scaffold(
      appBar: AppBar(title: Text('Product ${widget.productId}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: ListTile(
              leading: const Icon(Icons.shopping_bag_outlined),
              title: Text('Demo product ${widget.productId}'),
              subtitle: const Text('9.99 USD'),
            ),
          ),
          const SizedBox(height: 8),
          InfoSection(
            title: 'Buy and share',
            children: <Widget>[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  AsyncButton(
                    label: 'Buy (tracks a purchase)',
                    icon: Icons.shopping_cart_checkout,
                    kind: AsyncButtonKind.filled,
                    onPressed: canCallSdk
                        ? () => runWithFeedback(
                            context,
                            () => demo.trackPurchase(widget.productId),
                          )
                        : null,
                  ),
                  AsyncButton(
                    label: 'Create share link',
                    icon: Icons.add_link,
                    onPressed: canCallSdk
                        ? () => runWithFeedback(context, _createShareLink)
                        : null,
                  ),
                ],
              ),
              if (shareUrl != null) CreatedLink(url: shareUrl),
              if (!canCallSdk)
                const SectionNote(
                  'Start the SDK with your key (see the home screen) to buy '
                  'and share.',
                ),
            ],
          ),
          const SizedBox(height: 8),
          InfoSection(
            title: link == null ? 'Opened from the app' : 'Opened from a link',
            children: <Widget>[
              if (link == null)
                SectionNote(
                  'Open a link with deep-link path /product/${widget.productId} '
                  'to see its data here.',
                )
              else
                LinkEventDetails(event: link),
            ],
          ),
        ],
      ),
    );
  }
}
