# Terpiez

A location-based Flutter collection game that turns the University of Maryland campus into a real-world discovery map. Players explore nearby locations, catch virtual creatures, build a collection, and inspect the location history of their finds.

Terpiez was developed for **CMSC436: Programming Handheld Systems at the University of Maryland** and demonstrates mobile mapping, geolocation, motion sensors, background services, local notifications, secure credential storage, and remote Redis data access.

---

## Features

- Displays the player's position and nearby Terpiez on OpenStreetMap
- Uses proximity checks to unlock catches near real-world coordinates
- Stores caught species, images, statistics, and catch history locally
- Uses device motion sensors during the catching interaction
- Sends local notifications when an uncaught Terpiez is nearby
- Runs Android proximity checks through a foreground background service
- Saves user progress locally and backs it up to the course Redis service
- Stores course Redis credentials with platform secure storage
- Restores cached collection data when the remote service is unavailable
- Includes custom sounds and a generated launcher icon

---

## Tech Stack

- Flutter and Dart
- `flutter_map` and OpenStreetMap
- `geolocator` and `latlong2`
- RedisJSON through the Dart `redis` client
- `flutter_secure_storage` and `shared_preferences`
- `sensors_plus`
- Local notifications and background services
- `audioplayers`

---

## How It Works

```txt
UMD course Redis service
        │
        ├── locations and species metadata
        ├── encoded images
        └── per-user backup state
        │
        ▼
TerpiezModel ── local cache / secure storage
        │
        ├── Stats
        ├── Finder map
        └── Caught collection and details
```

The app fetches course-provided world data after the user signs in with their own CMSC436 Redis credentials. Credentials are never hardcoded in the repository and are stored using the operating system's secure credential store.

---

## How to Run

### Prerequisites

- Flutter SDK compatible with Dart 3.10 or newer
- Android Studio or Xcode
- A physical device for location, motion, and background-service testing
- Authorized CMSC436 Redis credentials and access to the course service

### Setup

```bash
git clone https://github.com/JacobDemory/terpiez.git
cd terpiez
flutter pub get
flutter run
```

The public source can be analyzed and built without credentials, but live species/location data requires the UMD course service. Availability outside the course environment is not guaranteed.

### Quality Checks

```bash
flutter analyze
flutter test
```

---

## Privacy and Course Infrastructure

- No usernames or passwords are included in this repository.
- Credentials entered in the app are stored through `flutter_secure_storage`.
- The Redis hostname identifies a course dependency, not a secret or a public demo service.
- Location access is required for the core discovery mechanic and background proximity alerts.
- Users should review platform permission prompts before enabling location services.

---

## What I Learned

- Coordinating asynchronous location, sensor, notification, and network streams
- Designing a state model that works across online and cached/offline data
- Handling mobile permissions and background execution constraints
- Parsing inconsistent remote JSON data defensively
- Persisting private credentials separately from application state
- Building a location-based game around real device capabilities

---

## Future Improvements

- Replace the course Redis dependency with a public portfolio backend
- Split the large application file into feature-focused modules
- Add mock repositories for reliable automated widget testing
- Add screenshots and a short gameplay walkthrough
- Improve accessibility, onboarding, and permission explanations
- Add automated integration tests for map and caching behavior
