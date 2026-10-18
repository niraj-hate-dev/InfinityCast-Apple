#ifndef RUNNER_LOGGER_H_
#define RUNNER_LOGGER_H_

#include <string>
#include <functional>
#include <fstream>
#include <iostream>
#include <mutex>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <windows.h>

namespace applecast {

using LogCallback = std::function<void(const std::string& tag, const std::string& message, const std::string& level)>;

class Logger {
 public:
  static Logger& Instance() {
    static Logger s_instance;
    return s_instance;
  }

  void SetCallback(LogCallback cb) {
    std::lock_guard<std::mutex> lock(mutex_);
    callback_ = std::move(cb);
  }

  void Log(const std::string& tag, const std::string& msg, const std::string& level = "info") {
    const auto now = std::chrono::system_clock::now();
    const auto in_time_t = std::chrono::system_clock::to_time_t(now);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()) % 1000;

    std::stringstream ss;
    struct tm tm_buf;
    localtime_s(&tm_buf, &in_time_t);
    ss << std::put_time(&tm_buf, "%Y-%m-%d %H:%M:%S")
       << '.' << std::setfill('0') << std::setw(3) << ms.count()
       << " [" << level << "] [" << tag << "] " << msg << "\n";
    const std::string formatted = ss.str();

    std::lock_guard<std::mutex> lock(mutex_);

    // 1. OutputDebugString for debugger / Sysinternals DebugView
    OutputDebugStringA(formatted.c_str());

    // 2. Standard streams
    if (level == "error") {
      std::cerr << formatted;
    } else {
      std::cout << formatted;
    }

    // 3. Persistent file log in %TEMP%\applecast_debug.log
    if (!file_initialized_) {
      char temp_path[MAX_PATH] = {0};
      if (GetTempPathA(MAX_PATH, temp_path) > 0) {
        log_file_path_ = std::string(temp_path) + "applecast_debug.log";
        log_file_.open(log_file_path_, std::ios::app);
        file_initialized_ = true;
      }
    }
    if (log_file_.is_open()) {
      log_file_ << formatted;
      log_file_.flush();
    }

    // 4. Flutter UI Callback
    if (callback_) {
      callback_(tag, msg, level);
    }
  }

  const std::string& log_file_path() const { return log_file_path_; }

 private:
  Logger() = default;
  ~Logger() {
    if (log_file_.is_open()) {
      log_file_.close();
    }
  }

  std::mutex mutex_;
  LogCallback callback_;
  std::ofstream log_file_;
  std::string log_file_path_;
  bool file_initialized_ = false;
};

inline void Log(const std::string& tag, const std::string& msg, const std::string& level = "info") {
  Logger::Instance().Log(tag, msg, level);
}

}  // namespace applecast

#endif  // RUNNER_LOGGER_H_
