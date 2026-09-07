#!/usr/bin/env python3
"""Build a couple of series and summarise them."""

import sys


class Series:
    """A named running total."""

    def __init__(self, name):
        self.name = name
        self.count = 0
        self.total = 0.0

    def add(self, value):
        self.count += 1
        self.total += value
        return self.total

    def summary(self):
        return f"{self.name}: {self.count} values, total {self.total:.1f}"


def scale(item, amount):
    """A proportional adjustment, in percent."""
    factor = amount / 100
    return item.total * factor


def factorial(n):
    if n <= 1:
        return 1
    return n * factorial(n - 1)


def main():
    series = {
        "squares": Series("squares"),
        "cubes": Series("cubes"),
    }
    values = [1, 4, 9, 16, 25, 36, 49, 64]
    for index, value in enumerate(values):
        amount = 10 * (index + 1)
        for item in series.values():
            item.add(value)
            scaled = scale(item, amount)
            print(f"{item.name} [{index}] {value} -> {scaled:.1f}")

    print(series["squares"].summary())
    print(series["cubes"].summary())
    print("factorial(10) =", factorial(10))
    report(series["cubes"], 25)

    if "--boom" in sys.argv:
        raise ValueError("series diverged")


def report(item, amount):
    label = item.summary()
    scaled = scale(item, amount)
    print(f"{label}, scaled {scaled:.1f}")
    return scaled


if __name__ == "__main__":
    main()
