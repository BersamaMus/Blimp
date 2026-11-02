#include "discord_status.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <chrono>
#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>

using flutter::EncodableMap;
using flutter::EncodableValue;
using Clock = std::chrono::steady_clock;

namespace {

// The kinds of message on Discord's pipe.
enum Opcode : uint32_t {
  kHandshake = 0,
  kFrame = 1,
  kClose = 2,
  kPing = 3,
  kPong = 4,
};

// Every message starts with its kind and its length.
struct Header {
  uint32_t opcode;
  uint32_t length;
};

struct Message {
  uint32_t opcode;
  std::string body;
};

// Anything longer isn't Discord's, so the connection is dropped.
constexpr uint32_t kLongestMessage = 1 << 20;

// How long to wait for Discord to answer on connecting.
constexpr auto kHandshakeWait = std::chrono::seconds(5);

// How often to look for Discord while it isn't running.
constexpr auto kConnectEvery = std::chrono::seconds(15);

// Discord allows a status change about this often; quicker skips wait, and
// only the latest song is sent.
constexpr auto kSendEvery = std::chrono::seconds(4);

bool Send(HANDLE pipe, uint32_t opcode, const std::string& body) {
  std::string message(sizeof(Header) + body.size(), '\0');
  Header header{opcode, static_cast<uint32_t>(body.size())};
  std::memcpy(message.data(), &header, sizeof(header));
  std::memcpy(message.data() + sizeof(header), body.data(), body.size());
  DWORD written = 0;
  return WriteFile(pipe, message.data(), static_cast<DWORD>(message.size()),
                   &written, nullptr) &&
         written == message.size();
}

// Takes a whole message if one has arrived, without waiting for one. False
// if the pipe is broken, as it is once Discord closes.
bool Receive(HANDLE pipe, std::optional<Message>& message) {
  message.reset();
  Header header{};
  DWORD read = 0;
  DWORD available = 0;
  if (!PeekNamedPipe(pipe, &header, sizeof(header), &read, &available,
                     nullptr)) {
    return false;
  }
  if (read < sizeof(header)) return true;
  if (header.length > kLongestMessage) return false;
  DWORD total = static_cast<DWORD>(sizeof(header)) + header.length;
  if (available < total) return true;
  std::vector<char> bytes(total);
  if (!ReadFile(pipe, bytes.data(), total, &read, nullptr) || read != total) {
    return false;
  }
  message = Message{header.opcode,
                    std::string(bytes.data() + sizeof(header), header.length)};
  return true;
}

// Answers whatever Discord has sent. Replies have to be read, or the pipe
// would fill up. False if the connection is over.
bool Tend(HANDLE pipe) {
  std::optional<Message> message;
  while (Receive(pipe, message)) {
    if (!message) return true;
    if (message->opcode == kClose) return false;
    if (message->opcode == kPing && !Send(pipe, kPong, message->body)) {
      return false;
    }
  }
  return false;
}

// Connects to the Discord app, which listens on the first of ten pipes that's
// free. Null if it isn't running, or turned Blimp down.
HANDLE Connect(const std::string& application_id,
               const std::atomic<bool>& stopping) {
  HANDLE pipe = INVALID_HANDLE_VALUE;
  for (int i = 0; i < 10 && pipe == INVALID_HANDLE_VALUE; i++) {
    std::wstring name = L"\\\\.\\pipe\\discord-ipc-" + std::to_wstring(i);
    pipe = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                       OPEN_EXISTING, 0, nullptr);
  }
  if (pipe == INVALID_HANDLE_VALUE) return nullptr;
  if (Send(pipe, kHandshake,
           "{\"v\":1,\"client_id\":\"" + application_id + "\"}")) {
    auto give_up = Clock::now() + kHandshakeWait;
    std::optional<Message> message;
    while (!stopping && Clock::now() < give_up && Receive(pipe, message)) {
      if (message) {
        if (message->opcode == kFrame) return pipe;
        break;
      }
      Sleep(50);
    }
  }
  CloseHandle(pipe);
  return nullptr;
}

bool SendActivity(HANDLE pipe, const std::string& activity) {
  static int nonce = 0;
  return Send(pipe, kFrame,
              "{\"cmd\":\"SET_ACTIVITY\",\"args\":{\"pid\":" +
                  std::to_string(GetCurrentProcessId()) +
                  ",\"activity\":" + activity + "},\"nonce\":\"" +
                  std::to_string(++nonce) + "\"}");
}

std::string Text(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  const auto* text =
      it == map.end() ? nullptr : std::get_if<std::string>(&it->second);
  return text ? *text : std::string();
}

}  // namespace

DiscordStatus::DiscordStatus(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/discord",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });
  worker_ = std::thread([this] { Run(); });
}

DiscordStatus::~DiscordStatus() {
  {
    std::lock_guard lock(mutex_);
    stopping_ = true;
  }
  wake_.notify_all();
  // In case it's stuck writing to a Discord that stopped reading.
  CancelSynchronousIo(worker_.native_handle());
  worker_.join();
}

void DiscordStatus::HandleCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (call.method_name() == "show" && args) {
    std::lock_guard lock(mutex_);
    application_id_ = Text(*args, "applicationId");
    activity_ = Text(*args, "activity");
  } else if (call.method_name() == "clear") {
    std::lock_guard lock(mutex_);
    activity_.clear();
  } else {
    result->NotImplemented();
    return;
  }
  wake_.notify_all();
  result->Success();
}

void DiscordStatus::Run() {
  HANDLE pipe = nullptr;
  std::string sent;
  auto next_connect = Clock::now();
  auto next_send = Clock::now();
  auto disconnect = [&] {
    if (pipe) CloseHandle(pipe);
    pipe = nullptr;
    sent.clear();
  };

  std::unique_lock lock(mutex_);
  while (!stopping_) {
    std::string wanted = activity_;
    std::string application_id = application_id_;
    lock.unlock();

    if (wanted.empty()) {
      // Discord takes the status down as soon as the pipe closes.
      disconnect();
      next_connect = Clock::now();
    } else {
      if (!pipe && Clock::now() >= next_connect) {
        pipe = Connect(application_id, stopping_);
        next_connect = Clock::now() + kConnectEvery;
      }
      if (pipe && wanted != sent && Clock::now() >= next_send) {
        if (SendActivity(pipe, wanted)) {
          sent = wanted;
          next_send = Clock::now() + kSendEvery;
        } else {
          disconnect();
        }
      }
      if (pipe && !Tend(pipe)) disconnect();
    }

    lock.lock();
    if (activity_.empty() && !pipe) {
      wake_.wait(lock, [&] { return stopping_ || !activity_.empty(); });
    } else {
      // Also the pulse that notices Discord closing or a wait being over.
      wake_.wait_for(lock, std::chrono::seconds(1),
                     [&] { return stopping_ || activity_ != wanted; });
    }
  }
  lock.unlock();
  disconnect();
}
