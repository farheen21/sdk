// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*library: nnbd=false*/

// @dart=2.5

/*class: Map:Map<K*,V*>,Object*/
abstract class Map<K, V> {
  /*member: Map.map:Map<K2*,V2*>* Function<K2,V2>(MapEntry<K2*,V2*>* Function(K*,V*)*)**/
  Map<K2, V2> map<K2, V2>(MapEntry<K2, V2> Function(K key, V value) f);
}
