module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'refactor', 'docs', 'chore', 'test',
      'build', 'ci', 'perf', 'security', 'revert',
    ]],
    'scope-empty': [0],
    'subject-case': [0],
    'header-max-length': [2, 'always', 100],
  },
};
