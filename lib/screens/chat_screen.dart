import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path/path.dart' as path;
import '../services/api_service.dart';
import 'login_screen.dart';
import 'package:google_sign_in/google_sign_in.dart';

class ChatScreen extends StatefulWidget {
  final String userName;
  const ChatScreen({super.key, required this.userName});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  File? _selectedImage;
  bool _isSending = false;

  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? uid;
  String? currentChatId;
  List<Map<String, dynamic>> _chatList = [];

  @override
  void initState() {
    super.initState();
    uid = _auth.currentUser?.uid;
    _loadChatList();
  }

  Future<void> _renameChat(String chatId) async {
    final controller = TextEditingController();
    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Chat'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter new title'),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newTitle != null && newTitle.isNotEmpty) {
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('chats')
          .doc(chatId)
          .update({'title': newTitle});
      _loadChatList();
      _showSnackBar("Chat renamed succesfully!");
    }
  }

  Future<void> _loadChatList() async {
    if (uid == null) return;
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .orderBy('created_at', descending: true)
        .get();

    _chatList = snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();

    if (_chatList.isNotEmpty) {
      setState(() {
        currentChatId = _chatList.first['id'];
      });
      _loadMessages();
    } else {
      await _startNewChat(); // 🚀 Auto-start chat if none
    }
  }


  Future<void> _startNewChat() async {
    if (uid == null) return;
    final newChatRef = _firestore.collection('users').doc(uid).collection('chats').doc();
    await newChatRef.set({
      'created_at': FieldValue.serverTimestamp(),
      'title': 'New Chat',
    });

    setState(() {
      currentChatId = newChatRef.id;
      _messages.clear();
    });

    _loadChatList();
    _addWelcomeMessage();
  }

  Future<void> _deleteChat(String chatId) async {
    if (uid == null) return;
    final messages = await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .get();
    for (final doc in messages.docs) {
      await doc.reference.delete();
    }
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(chatId)
        .delete();

    if (currentChatId == chatId) {
      setState(() {
        currentChatId = null;
        _messages.clear();
      });
    }
    _loadChatList();
    _showSnackBar("🗑️ Chat deleted");
  }

  Future<void> _loadMessages() async {
    if (uid == null || currentChatId == null) return;
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(currentChatId)
        .collection('messages')
        .orderBy('timestamp')
        .get();

    final history = snapshot.docs.map((doc) => doc.data()).toList();
    setState(() => _messages..clear()..addAll(history));
    _scrollToBottom();
  }

  Future<void> _addWelcomeMessage() async {
    if (uid == null || currentChatId == null) return;
    final welcome = {
      'type': 'bot',
      'text': "Hello ${widget.userName.split(" ").first}! 👋 Need help identifying a paddy disease? Upload an image or ask me anything about your crops!",
      'imageUrl': null,
      'timestamp': Timestamp.now(),
    };
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(currentChatId)
        .collection('messages')
        .add(welcome);
    setState(() => _messages.add(welcome));
  }

  Future<void> _sendMessage({String? text, File? image}) async {
    if ((text == null || text.trim().isEmpty) && image == null) return;
    if (uid == null || currentChatId == null) return;

    final userMessage = {
      'type': 'user',
      'text': text ?? 'Uploaded an image',
      'imageUrl': image?.path,
      'timestamp': Timestamp.now(),
    };

    setState(() {
      _messages.add(userMessage);
      _isSending = true;
    });
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(currentChatId)
        .collection('messages')
        .add(userMessage);
    _scrollToBottom();

    String botReply = "";
    String? uploadedImageUrl;
    const double confidenceThreshold = 75.0;

    try {
      if (image != null) {
        uploadedImageUrl = await _uploadImageToFirebase(image);
        if (uploadedImageUrl == null) throw Exception("Failed to upload image to Firebase.");

        final result = await ApiService.getDiseaseFromImage(image, uploadedImageUrl);
        final diseaseName = result['prediction'] ?? "Unknown";
        final confidence = result['confidence'] != null
            ? double.parse(result['confidence'].toString()) * 100
            : null;

        final formattedName = diseaseName.replaceAll('_', ' ').split(' ').map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');

        if (confidence != null && confidence >= confidenceThreshold) {
          botReply = "I'm ${confidence.toStringAsFixed(2)}% confident that this is $formattedName";
        } else {
          botReply =
          "⚠️ I'm only ${confidence?.toStringAsFixed(2) ?? "?"}% confident about this prediction. Can you please try uploading a clearer image.";
        }
      } else if (text != null && text.trim().isNotEmpty) {
        final rasaReply = await ApiService.getRasaResponse(text.trim());
        botReply = rasaReply;
      }
    } catch (e) {
      botReply = "⚠️ Error: ${e.toString()}";
      _showSnackBar("❌ Image upload failed", backgroundColor: Colors.red);
    }

    final typingMsg = {
      'type': 'bot',
      'text': 'PaddyBot is typing...',
      'imageUrl': null,
      'timestamp': Timestamp.now(),
    };

    setState(() => _messages.add(typingMsg));
    _scrollToBottom();
    await Future.delayed(const Duration(seconds: 1));
    setState(() => _messages.removeLast());

    final botMessage = {
      'type': 'bot',
      'text': botReply,
      'imageUrl': uploadedImageUrl,
      'timestamp': Timestamp.now(),
    };

    setState(() {
      _messages.add(botMessage);
      _controller.clear();
      _selectedImage = null;
      _isSending = false;
    });
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('chats')
        .doc(currentChatId)
        .collection('messages')
        .add(botMessage);
    _scrollToBottom();
  }

  Future<String?> _uploadImageToFirebase(File imageFile) async {
    try {
      final fileName = path.basename(imageFile.path);
      final destination = 'uploads/${DateTime.now().millisecondsSinceEpoch}_$fileName';
      final ref = FirebaseStorage.instance.ref(destination);
      final uploadTask = await ref.putFile(imageFile);
      return await ref.getDownloadURL();
    } catch (e) {
      print('Upload failed: $e');
      return null;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100)).then((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  void _showSnackBar(String message, {Color? backgroundColor}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor ?? Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked != null) {
      setState(() => _selectedImage = File(picked.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          //backgroundColor: const Color(0xFF102820),
          backgroundColor: const Color (0xFF000000),
          title: const Text("PaddySnap", style: TextStyle(color: Color(0xFFB4FF9F), fontWeight: FontWeight.bold)),
        ),
        drawer: Drawer(
          backgroundColor: const Color(0xFF102820),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 40, bottom: 0),
                alignment: Alignment.centerLeft,
                color: Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Chats", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text("New Chat"),
                      onPressed: _startNewChat,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _chatList.isEmpty
                    ? Center(
                  child: GestureDetector(
                    onTap: () => _showSnackBar("Tap the green + New Chat button to get started!"),
                    child: const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        '📭 No chats yet.\nTap + New Chat to start!',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                )
                    : ListView.builder(
                  itemCount: _chatList.length,
                  itemBuilder: (context, index) {
                    final chat = _chatList[index];
                    return ListTile(
                      title: Text(
                        chat['title'] ?? 'Chat',
                        style: const TextStyle(color: Colors.white),
                      ),
                      selected: chat['id'] == currentChatId,
                      onTap: () {
                        setState(() {
                          currentChatId = chat['id'];
                          _messages.clear();
                        });
                        Navigator.pop(context);
                        _loadMessages();
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.blueAccent),
                            onPressed: () => _renameChat(chat['id']),
                            tooltip: 'Rename Chat',
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deleteChat(chat['id']),
                            tooltip: 'Delete Chat',
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              // 👇 Add this block at the bottom of your Column
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text("Logout", style: TextStyle(color: Colors.white)),
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text("Confirm Logout"),
                        content: const Text("Are you sure you want to log out?"),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context), // Cancel
                            child: const Text("Cancel"),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () async {
                              Navigator.pop(context); // Close dialog first
                              await FirebaseAuth.instance.signOut();
                              await FirebaseAuth.instance.signOut();
                              await GoogleSignIn().signOut();
                              // Navigate directly to LoginScreen and clear stack
                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(builder: (_) => const LoginScreen()),
                                    (route) => false,
                              );
                            },
                            child: const Text("Logout"),
                          ),
                        ],
                      ),
                    );
                  }
              ),
            ],
          ),
        ),


        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  final isUser = message['type'] == 'user';
                  final time = (message['timestamp'] as Timestamp).toDate();
                  final timeString = TimeOfDay.fromDateTime(time).format(context);

                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isUser ? Colors.green[300] : Colors.green[100],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.green.shade700, width: 0.5),
                      ),
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Column(
                        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                        children: [
                          Text(
                            isUser ? "You" : "PaddyBot",
                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green.shade900),
                          ),
                          if (message['text'] != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
                              child: Text(message['text'], style: const TextStyle(fontSize: 15, color: Colors.black)),
                            ),
                          if (message['imageUrl'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: isUser
                                  ? Image.file(File(message['imageUrl']), width: 200, fit: BoxFit.cover)
                                  : Image.network(message['imageUrl'], width: 200, fit: BoxFit.cover),
                            ),
                          Text(timeString, style: const TextStyle(fontSize: 10, color: Colors.black54)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_selectedImage != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        Image.file(_selectedImage!, width: 80),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedImage = null;
                              });
                            },
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(4),
                              child: const Icon(Icons.close, color: Colors.white, size: 16),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    const Text("Image ready to send"),
                  ],
                ),
              ),

            const Divider(height: 1),
            if (_selectedImage == null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.image),
                      onPressed: () => _pickImage(ImageSource.gallery),
                    ),
                    IconButton(
                      icon: const Icon(Icons.camera_alt),
                      onPressed: () => _pickImage(ImageSource.camera),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(text: _controller.text),
                        decoration: const InputDecoration(
                          hintText: 'Type your message...',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: _isSending ? const CircularProgressIndicator() : const Icon(Icons.send),
                      onPressed: _isSending ? null : () => _sendMessage(text: _controller.text),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.image),
                      onPressed: () => _pickImage(ImageSource.gallery),
                    ),
                    IconButton(
                      icon: const Icon(Icons.camera_alt),
                      onPressed: () => _pickImage(ImageSource.camera),
                    ),
                    const Text("Send the image"),
                    const Spacer(),
                    IconButton(
                      icon: _isSending ? const CircularProgressIndicator() : const Icon(Icons.send),
                      onPressed: _isSending ? null : () => _sendMessage(image: _selectedImage),
                    ),
                  ],
                ),
              ),

          ],
        ),
      ),
    );
  }
}


