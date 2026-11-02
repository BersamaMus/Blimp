#ifndef RUNNER_DISCORD_STATUS_H_
#define RUNNER_DISCORD_STATUS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

// Shows what the Dart side sends on the "blimp/discord" channel (see
// lib/services/discord_status.dart) on the user's Discord profile. Talks to
// the Discord app on this PC through its local pipe. On its own thread, so a
// Discord that's starting up or stuck can't hold up the window.
class DiscordStatus {
 public:
  explicit DiscordStatus(flutter::BinaryMessenger* messenger);
  ~DiscordStatus();

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Keeps Discord showing activity_, for as long as there is one.
  void Run();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // What Discord should show; empty for nothing. Held under mutex_.
  std::mutex mutex_;
  std::condition_variable wake_;
  std::string application_id_;
  std::string activity_;

  std::atomic<bool> stopping_ = false;
  std::thread worker_;
};

#endif  // RUNNER_DISCORD_STATUS_H_
