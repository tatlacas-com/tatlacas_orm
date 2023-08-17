import '../sql.dart';

import 'base_storage.dart';
import 'sqflite_common_db_context.dart';

class SqfliteCommonStorage<TEntity extends IEntity>
    extends BaseStorage<TEntity, SqfliteCommonDbContext> {
  const SqfliteCommonStorage(TEntity entityType,
      {required SqfliteCommonDbContext dbContext})
      : super(entityType, dbContext: dbContext);
}
