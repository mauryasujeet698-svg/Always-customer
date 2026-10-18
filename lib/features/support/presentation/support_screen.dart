import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key, this.orderId});

  final String? orderId;

  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  final _subject = TextEditingController();
  final _orderId = TextEditingController();
  final _message = TextEditingController();
  String _area = 'Order';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _orderId.text = widget.orderId ?? '';
  }

  @override
  void dispose() {
    _subject.dispose();
    _orderId.dispose();
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Customer support')),
        body: Center(
          child: FilledButton(
            onPressed: () => context.push('/login'),
            child: const Text('Sign in to contact support'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Customer support')),
      body: ListView(
        key: const PageStorageKey<String>('customer-support-scroll'),
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: ListTile(
              leading: Icon(Icons.support_agent_outlined, size: 30),
              title: Text('How can we help?'),
              subtitle: Text('Send our team the details. Do not include passwords or OTPs.'),
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _area,
            decoration: const InputDecoration(labelText: 'What do you need help with?'),
            items: const [
              DropdownMenuItem(value: 'Order', child: Text('Order')),
              DropdownMenuItem(value: 'Delivery', child: Text('Delivery')),
              DropdownMenuItem(value: 'Ride', child: Text('Local ride')),
              DropdownMenuItem(value: 'Account', child: Text('Login or account')),
              DropdownMenuItem(value: 'Payment', child: Text('Payment')),
              DropdownMenuItem(value: 'Other', child: Text('Other')),
            ],
            onChanged: _busy ? null : (value) {
              if (value != null) setState(() => _area = value);
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _orderId,
            decoration: const InputDecoration(labelText: 'Order or ride ID (optional)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _subject,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Subject'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _message,
            minLines: 4,
            maxLines: 8,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Describe your issue'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _submit(user),
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send_outlined),
            label: Text(_busy ? 'Sending…' : 'Send support request'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit(User user) async {
    if (_subject.text.trim().isEmpty || _message.text.trim().length < 8) {
      setState(() => _error = 'Enter a subject and provide a few details about the issue.');
      return;
    }
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      await FirebaseFirestore.instance.collection('supportTickets').add({
        'requesterId': user.uid,
        'requesterRole': 'customer',
        'requesterEmail': user.email ?? '',
        'requesterPhone': user.phoneNumber ?? '',
        'area': _area,
        'orderId': _orderId.text.trim(),
        'subject': _subject.text.trim(),
        'message': _message.text.trim(),
        'status': 'open',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.check_circle_outline, color: Colors.green, size: 40),
            title: const Text('Request sent'),
            content: const Text('Your support request has been submitted. Keep your order or ride ID for reference.'),
            actions: [
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  context.pop();
                },
                child: const Text('Done'),
              ),
            ],
          ),
        );
      }
    } on FirebaseException catch (error) {
      if (mounted) setState(() => _error = 'Could not send request (${error.code}). Please try again.');
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send request. Check your connection and retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
