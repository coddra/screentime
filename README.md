# Screentime

Measure your screen time and app usage on bspwm. Logs daily.



## Usage

Start daemon:
```sh
screentime.sh subscribe bspwm &
```

Subscribe to systemd hooks:
```sh
screentime.sh subscribe systemd
```

Print today's app usage:
```sh
screentime.sh
# or
screentime.sh show
```

For more information see:
```sh
screentime.sh help
```



## Example

```sh
Screen time today:
 0:51:11 ██████████████████████████████  qutebrowser
 0:40:13 ████████████████████████        Code
 0:13:18 ████████                        ranger
 0:12:49 ████████                        Alacritty
 0:00:35                                 idle

Total time: 1:58:06
```
